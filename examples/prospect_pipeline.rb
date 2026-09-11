# frozen_string_literal: true

# The pipeline, as a workflow.
#
#   idea → goal.md → mission .mmd → advance every todo with a verifier
#        → CRM next actions + drafted (never sent) outreach → weekly report
#
# This is the *engine* of a CRM/product pipeline, not its product surface: no
# auth, no tenancy, no billing, no UI. What it replaces is the part that
# usually hides in controllers, background jobs and services — and it replaces
# it with something you can read in one sitting, re-run, resume after a crash,
# and hand to any harness, because every artifact it writes is a file:
#
#   $PROSPECT_ROOT/epics/<slug>_<date>/goal.md
#   $PROSPECT_ROOT/epics/<slug>_<date>/missions/<mission>.mmd     (Mermaid kanban)
#   $PROSPECT_ROOT/crm/people.json
#   $PROSPECT_ROOT/crm/outbox/<person>.md                         (drafts)
#   $PROSPECT_ROOT/crm/weekly-report.md
#
# The `.mmd` is the contract `pipeline_prospect` already publishes: a human can
# edit it in `$EDITOR`, their Rails app syncs its index from it, and
# `Runes::Kanban` reads and writes it here. Nothing in this file is
# pipeline_prospect-specific except the folder shape and the kanban grammar —
# swap the prompts and the columns and it is your pipeline.
#
# Run it:
#
#   bin/runes-workflow execute examples/prospect_pipeline.rb idea="Former 3 partenaires..."
#   PROSPECT_ROOT=/path/to/pipeline_prospect bin/runes-workflow execute examples/prospect_pipeline.rb
#
# Needs a provider key for the agent/chat runes (see README). The suite runs
# this very file with the provider seam faked, so the example cannot rot:
# test/prospect_pipeline_test.rb.

execute do
  # --- 1. who we are, where we write, what we were asked ------------------

  # The block's return value is the sub-workflow's input; the documented block
  # contract hands it the scope value (here: the workflow params).
  call(:prepared, run: :prepare) { |_my, scope_value, _index| scope_value }

  # --- 2. idea → goal.md ---------------------------------------------------

  call(:goals, run: :brainstorm) { from(call!(:prepared)) }

  # --- 3. goal → mission kanban (.mmd) ------------------------------------

  call(:mission, run: :plan) { from(call!(:goals)) }

  # --- 4. advance every todo: work, verify, move the card ------------------

  map(:advanced, run: :advance_todo) do |my|
    plan = from(call!(:mission))
    my.items = plan[:todos].map do |todo|
      { mission_path: plan[:mission_path], mission_code: plan[:mission_code],
        title: todo[:title], assignee: todo[:assignee] }
    end
  end

  # --- 5. the CRM leg: what to do next, and what to say --------------------

  # `collect` sees the map's iterations from a *step*, not from a call block.
  ruby(:advanced_values) { collect(map!(:advanced)) }

  call(:crm, run: :crm_actions) do
    from(call!(:mission)).merge(advanced: ruby!(:advanced_values).value)
  end

  # --- 6. the report a human actually reads --------------------------------

  call(:report, run: :weekly_report) { from(call!(:crm)) }

  outputs do |_scope_value, _scope_index|
    {
      epic_code: from(call!(:prepared))[:epic_code],
      goal_path: from(call!(:goals))[:goal_path],
      mission_path: from(call!(:mission))[:mission_path],
      todos: from(call!(:mission))[:todos].size,
      advanced: collect(map!(:advanced)),
      next_actions: from(call!(:crm))[:next_actions],
      drafts: from(call!(:crm))[:drafts],
      report_path: from(call!(:report))[:report_path],
      # The run reports its own link check: every `#E-`/`#M-` reference it
      # wrote resolved, or a list of the ones that did not.
      references: from(call!(:report))[:references],
      missing_refs: from(call!(:report))[:missing_refs]
    }
  end
end

# ---------------------------------------------------------------------------
# 1. configuration
# ---------------------------------------------------------------------------

execute(:prepare) do
  ruby(:config) do |_my, scope_value, _index|
    kwargs = scope_value.respond_to?(:kwargs) ? scope_value.kwargs : {}
    root = ENV["PROSPECT_ROOT"].to_s
    root = File.join(Dir.pwd, "tmp", "prospect-pipeline") if root.strip.empty?

    {
      root: root,
      idea: (kwargs[:idea] || ENV["PROSPECT_IDEA"] ||
             "Trouver 10 PME de 10 à 100 employés intéressées par un CRM qui " \
             "transforme une idée en mission exécutée").to_s,
      owner: (kwargs[:owner] || ENV["PROSPECT_OWNER"] || "Richard").to_s,
      today: Date.today.to_s,
      slug: nil,
      epic_code: nil,
      epic_dir: nil
    }
  end

  # Mints #E-001 from the epics already on disk and creates the folder — the
  # same shape pipeline_prospect reads.
  ruby(:epic) do
    config = ruby!(:config).value
    require "fileutils"
    epics_dir = File.join(config[:root], "epics")
    FileUtils.mkdir_p(epics_dir)

    # The raw idea is stored as a content-addressed document (ab/cd/<sha>.txt),
    # the layout a harness and their app both read — so the goal can reference
    # it by path instead of quoting it, and two identical ideas cost one file.
    doc = Runes::DocStore.new(root: File.join(config[:root], "documents"))
                       .put(config[:idea], ext: "txt")
    config = config.merge(doc_path: doc[:path], doc_sha: doc[:sha])

    existing = Dir.glob(File.join(epics_dir, "*", "goal.md")).map { |path| File.read(path) }
    code = Runes::Kanban.next_code(existing, prefix: "E")
    slug = config[:idea].downcase.gsub(/[^a-z0-9]+/, "_").split("_").first(4).join("_")
    dir = File.join(epics_dir, "#{slug}_#{config[:today]}")
    FileUtils.mkdir_p(File.join(dir, "missions"))

    config.merge(slug: slug, epic_code: code, epic_dir: dir)
  end

  outputs { |_value, _index| ruby!(:epic).value }
end

# ---------------------------------------------------------------------------
# 2. brainstorming: the idea becomes a goal
# ---------------------------------------------------------------------------

execute(:brainstorm) do
  ruby(:config) { |_my, scope_value, _index| scope_value }

  agent(:goal) do
    config = ruby!(:config).value
    <<~PROMPT
      You are the brainstorming half of a small team. Turn this raw idea into a
      single, decided goal: one sentence of outcome, three success criteria, and
      the smallest first release that would prove it.

      IDEA: #{config[:idea]}
      OWNER: #{config[:owner]}
      TODAY: #{config[:today]}

      Answer in Markdown, no preamble.
    PROMPT
  end

  ruby(:write_goal) do
    config = ruby!(:config).value
    goal = agent!(:goal).response.to_s.strip
    body = <<~MD
      # #{config[:idea]}

      <!-- code: #{config[:epic_code]} -->

      > Épic #{Runes::Kanban.reference(config[:epic_code])} · créé le #{config[:today]} · porté par #{config[:owner]}
      > Idée d'origine : `#{config[:doc_path]}` (sha256 #{config[:doc_sha][0, 12]}…)

      #{goal}

      ---
      _Écrit par `examples/prospect_pipeline.rb` — le but est un fichier, donc un
      harness peut le relire, le corriger, et le workflow le reprendra._
    MD
    path = File.join(config[:epic_dir], "goal.md")
    File.write(path, body)

    # The marker above is what `Runes::Index` resolves `#E-001` to; a reference
    # that points nowhere is worth knowing about at write time, not at read.
    linked = Runes::Index.new(root: config[:root]).link(body, from: path)
    { goal_path: path, goal: goal, missing_refs: linked[:missing] }
  end

  outputs do |_value, _index|
    ruby!(:config).value.merge(goal_path: ruby!(:write_goal).goal_path, goal: ruby!(:write_goal).goal)
  end
end

# ---------------------------------------------------------------------------
# 3. planning: the goal becomes a mission kanban
# ---------------------------------------------------------------------------

execute(:plan) do
  ruby(:input) { |_my, scope_value, _index| scope_value }

  agent(:todos) do
    goal = ruby!(:input).goal
    <<~PROMPT
      Break this goal into between three and six todos a small team can execute
      this week. Answer with JSON only:

      {"mission": "short mission title", "todos": [{"title": "…", "assignee": "…"}]}

      GOAL:
      #{goal}
    PROMPT
  end

  ruby(:write_mission) do
    input = ruby!(:input).value
    raw = agent!(:todos).response.to_s
    plan = begin
      JSON.parse(raw[/\{.*\}/m].to_s, symbolize_names: true)
    rescue JSON::ParserError, TypeError
      nil
    end
    # A plan that cannot be parsed is not a plan: fail loudly, with the step
    # named, instead of writing an empty mission and calling it success.
    fail!("planner returned unparseable todos (#{raw[0, 120].inspect})") if plan.nil? || plan[:todos].to_a.empty?

    require "fileutils"
    missions_dir = File.join(input[:epic_dir], "missions")
    FileUtils.mkdir_p(missions_dir)
    existing = Dir.glob(File.join(missions_dir, "*.mmd")).map { |path| File.read(path) }
    code = Runes::Kanban.next_code(existing, prefix: "M")
    mission = plan[:mission].to_s.empty? ? "Mission" : plan[:mission].to_s
    file = File.join(missions_dir, "#{mission.downcase.gsub(/[^a-z0-9]+/, "_")[0, 40]}.mmd")

    text = Runes::Kanban.render(
      mission: mission, code: code, created_at: input[:today],
      epic: "#{input[:idea]} (#{input[:epic_code]})",
      columns: { "todo" => plan[:todos].map { |t| { title: t[:title], assignee: t[:assignee] } } }
    )
    Runes::Kanban.write(file, text)
    # Trust but verify: the file goes to a human, an editor and their app, so a
    # grammar error is a failure now, not a surprise later.
    errors = Runes::Kanban.validate(text)
    fail!("wrote an invalid mission: #{errors.first}") unless errors.empty?

    { mission_path: file, mission_code: code, mission: mission, todos: plan[:todos],
      epic_dir: input[:epic_dir], epic_code: input[:epic_code], root: input[:root] }
  end

  outputs { |_value, _index| ruby!(:write_mission).value }
end

# ---------------------------------------------------------------------------
# 4. execution: one sub-workflow per todo, with a verifier
# ---------------------------------------------------------------------------

execute(:advance_todo) do
  ruby(:todo) { |_my, scope_value, _index| scope_value }

  agent(:work) do
    todo = ruby!(:todo).value
    <<~PROMPT
      Execute this todo for a small marketing team and report what you did in
      three lines maximum. Be concrete: name the file, the list or the decision.

      TODO: #{todo[:title]}
      ASSIGNEE: #{todo[:assignee]}
    PROMPT
  end

  # The verifier is a second, independent read of the work: the pattern that
  # makes a pipeline safe to run unattended is not "the model said it is done".
  agent(:verdict) do
    todo = ruby!(:todo).value
    work = agent!(:work).response.to_s
    <<~PROMPT
      You are the verifier. Decide whether this todo is genuinely done from the
      report alone. Answer with JSON only:

      {"verdict": "pass" or "fail", "reason": "one short sentence"}

      TODO: #{todo[:title]}
      REPORT: #{work}
    PROMPT
  end

  ruby(:tick) do
    todo = ruby!(:todo).value
    raw = agent!(:verdict).response.to_s
    verdict = begin
      JSON.parse(raw[/\{.*\}/m].to_s, symbolize_names: true)
    rescue JSON::ParserError, TypeError
      nil
    end
    verdict ||= { verdict: "fail", reason: "unparseable verdict #{raw[0, 80].inspect}" }
    passed = verdict[:verdict].to_s == "pass"

    # The kanban is moved, not rewritten: the same file an editor or their app
    # may be holding, with the reason kept as free text.
    updated = Runes::Kanban.advance_file(todo[:mission_path], title: todo[:title],
                                                             to: passed ? "done" : "blocked",
                                                             note: "#{verdict[:verdict]}: #{verdict[:reason]}")
    errors = Runes::Kanban.validate(updated)
    fail!("the mission file no longer validates: #{errors.first}") unless errors.empty?
    status = Runes::Kanban.parse(updated)[:header]["status"]

    { title: todo[:title], assignee: todo[:assignee], verdict: verdict[:verdict],
      reason: verdict[:reason], mission_status: status }
  end

  outputs { |_value, _index| ruby!(:tick).value }
end

# ---------------------------------------------------------------------------
# 5. the CRM leg: who to talk to next, and what to say
# ---------------------------------------------------------------------------

execute(:crm_actions) do
  ruby(:input) { |_my, scope_value, _index| scope_value }

  # Deterministic first: "who to contact next" is a rule, not a vibe. The model
  # is only asked for the wording, later.
  ruby(:next_actions) do
    input = ruby!(:input).value
    require "fileutils"
    crm_dir = File.join(input[:root], "crm")
    FileUtils.mkdir_p(File.join(crm_dir, "outbox"))
    people_path = File.join(crm_dir, "people.json")
    # First run: the CRM file does not exist yet, so seed the demo contacts.
    people = begin
      JSON.parse(File.read(people_path), symbolize_names: true)
    rescue Errno::ENOENT, JSON::ParserError, TypeError
      nil
    end
    people ||= [
      { name: "Jean Dupont", company: "Dupont & Fils", stage: "contacted",
        last_touch: (Date.today - 12).to_s },
      { name: "Marie Martin", company: "Martin Logistics", stage: "new",
        last_touch: (Date.today - 21).to_s },
      { name: "Samir Haddad", company: "Haddad Industries", stage: "demo",
        last_touch: (Date.today - 3).to_s }
    ]
    File.write(people_path, JSON.pretty_generate(people))

    passed = Array(input[:advanced]).select { |todo| todo[:verdict] == "pass" }.map { |todo| todo[:assignee] }
    actions = people.map do |person|
      days = (Date.today - Date.parse(person[:last_touch])).to_i
      action =
        if person[:stage] == "demo" && days > 2 then "proposer la suite (devis)"
        elsif days >= 14 then "relance personnalisée (silence depuis #{days} j)"
        elsif passed.include?(person[:name]) then "partager ce qui vient d'être fait"
        else "envoyer la documentation de lancement"
        end
      person.merge(action: action, days_since_touch: days)
    end.sort_by { |person| -person[:days_since_touch] }

    { crm_dir: crm_dir, people_path: people_path, next_actions: actions,
      mission_path: input[:mission_path], mission_code: input[:mission_code],
      epic_code: input[:epic_code], advanced: input[:advanced], root: input[:root] }
  end

  # Then the wording, one draft per contact — written to disk, never sent.
  map(:drafts, run: :draft_outreach) do |my|
    crm = ruby!(:next_actions).value
    my.items = crm[:next_actions].first(2).map { |person| person.merge(crm_dir: crm[:crm_dir]) }
  end

  ruby(:collect) do
    { next_actions: ruby!(:next_actions).next_actions,
      # `advanced` travels on: the report says what moved as well as what is next.
      advanced: ruby!(:next_actions).advanced,
      people_path: ruby!(:next_actions).people_path,
      mission_path: ruby!(:next_actions).mission_path,
      mission_code: ruby!(:next_actions).mission_code,
      epic_code: ruby!(:next_actions).epic_code,
      drafts: collect(map!(:drafts)),
      root: ruby!(:next_actions).root }
  end

  outputs { |_value, _index| ruby!(:collect).value }
end

execute(:draft_outreach) do
  ruby(:person) { |_my, scope_value, _index| scope_value }

  agent(:draft) do
    person = ruby!(:person).value
    <<~PROMPT
      Write a short, specific outreach message (email, under 120 words, no
      exclamation marks, no "je me permets") for this contact. French.

      CONTACT: #{person[:name]} (#{person[:company]}), étape: #{person[:stage]}
      DERNIER CONTACT: il y a #{person[:days_since_touch]} jours
      ACTION VISÉE: #{person[:action]}
    PROMPT
  end

  ruby(:write_draft) do
    person = ruby!(:person).value
    draft = agent!(:draft).response.to_s.strip
    file = File.join(person[:crm_dir], "outbox", "#{person[:name].downcase.gsub(/\W+/, '_')}.md")
    File.write(file, "# #{person[:name]} — #{person[:action]}\n\n#{draft}\n\n" \
                     "_Brouillon généré, non envoyé : l'envoi reste humain._\n")
    { person: person[:name], path: file, action: person[:action] }
  end

  outputs { |_value, _index| ruby!(:write_draft).value }
end

# ---------------------------------------------------------------------------
# 6. the report
# ---------------------------------------------------------------------------

execute(:weekly_report) do
  ruby(:input) { |_my, scope_value, _index| scope_value }

  chat(:summary) do
    crm = ruby!(:input).value
    <<~PROMPT
      Summarise this pipeline state for its owner in five bullet points, in
      French, with no greeting and no filler: what moved, what is stuck, and
      what to do first tomorrow.

      NEXT ACTIONS: #{crm[:next_actions].map { |p| "#{p[:name]}: #{p[:action]} (#{p[:days_since_touch]} j)" }.join('; ')}
      MISSION: #{crm[:mission_path]}
      DRAFTS: #{Array(crm[:drafts]).map { |d| "#{d[:person]} → #{d[:path]}" }.join('; ')}
    PROMPT
  end

  ruby(:write_report) do
    crm = ruby!(:input).value
    summary = chat!(:summary).response.to_s.strip
    path = File.join(crm[:root], "crm", "weekly-report.md")
    body = <<~MD
      # Pipeline — #{Date.today}

      ## Ce qui a bougé
      #{Array(crm[:advanced]).map { |t| "- #{t[:title]} — **#{t[:verdict]}** (#{t[:reason]})" }.join("\n")}

      ## À faire ensuite
      #{crm[:next_actions].map { |p| "- **#{p[:name]}** (#{p[:company]}) : #{p[:action]} — silence depuis #{p[:days_since_touch]} j" }.join("\n")}

      ## Brouillons prêts (non envoyés)
      #{Array(crm[:drafts]).map { |d| "- #{d[:person]} → `#{d[:path]}`" }.join("\n")}

      ## Lecture
      #{summary}

      ---
      _Généré par `examples/prospect_pipeline.rb` — épic ##{crm[:epic_code]} · mission ##{crm[:mission_code]}_
    MD

    # The report names its epic and mission by code. Resolving those references
    # through the files (not a database) is what lets a human trust the pointer,
    # and a reference that resolves nowhere is reported rather than hidden.
    linked = Runes::Index.new(root: crm[:root]).link(body, from: crm[:mission_path])
    body += linked[:missing].empty? ? "" : "\n> Références non résolues : #{linked[:missing].join(', ')}\n"
    File.write(path, body)
    { report_path: path, summary: summary, references: linked[:resolved].keys,
      missing_refs: linked[:missing] }
  end

  outputs { |_value, _index| ruby!(:write_report).value.merge(next_actions: ruby!(:input).next_actions) }
end
