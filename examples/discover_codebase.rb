# frozen_string_literal: true

# Discovery phase prototype: brief + repo -> verified discovery card.
#
#   RUNES_DISCOVERY_BRIEF="Add a kanban board to the observatory" \
#   RUNES_DISCOVERY_REPO=/path/to/repo \
#   RUNES_DISCOVERY_OUT=/path/to/out \
#     bin/runes-workflow execute examples/discover_codebase.rb
#
# Design: docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md
#
# The model never plans and never reads the repo directly: Ruby builds the
# five renderings of one state_id (tree, imports, tests, churn, docs), Ruby
# picks candidate files, the model fills one typed finding.v1 slot per
# fresh-context call, and Ruby resolves every anchor mechanically. The card
# (discovery.json + discovery_card.md) is assembled by Ruby — the model only
# filled slots. The suite runs this file offline with the provider seam
# scripted: test/discovery_test.rb.

execute do
  # ── Phase 0 — world state (deterministic, no model) ──────────────────

  ruby(:world) do
    repo = File.expand_path(ENV.fetch('RUNES_DISCOVERY_REPO', Dir.pwd))
    brief = ENV.fetch('RUNES_DISCOVERY_BRIEF', 'Describe this codebase and propose one improvement.')
    out_dir = File.expand_path(ENV.fetch('RUNES_DISCOVERY_OUT', File.join(Dir.pwd, 'tmp', 'discovery')))
    renderings = Runes::Discovery::Renderings.build(repo: repo, brief: brief)
    { repo: repo, brief: brief, out_dir: out_dir, renderings: renderings }
  end

  # ── Phase 1 — brief split (one fresh context, typed JSON) ────────────

  chat(:brief_split) do
    world = ruby!(:world).value
    <<~PROMPT
      #{world[:brief]}

      Restate this task in one sentence, then list 3-6 subproblems.
      Mark each codebase-dependent or self-contained.
      Output JSON only:
      {"restatement": "...", "subproblems": [{"id": "S1", "text": "...", "needs_codebase": true}]}
      If the task is ambiguous beyond one clarification, output {"decline": "reason"}.
    PROMPT
  end

  ruby(:subproblems) do
    raw = chat!(:brief_split).response.to_s
    json = begin
      JSON.parse(raw[/\{.*\}/m].to_s)
    rescue JSON::ParserError, TypeError
      nil
    end
    fail! "brief_split returned unparseable JSON: #{raw[0, 120].inspect}" if json.nil?
    fail! "brief_split declined: #{json['decline']}" if json['decline']

    world = ruby!(:world).value
    subs = Array(json['subproblems'])
    # The map items carry everything the sub-workflow needs: the outer
    # steps are not visible from inside a `run:` sub-workflow.
    subs.map do |sp|
      { 'sp' => sp, 'repo' => world[:repo], 'renderings' => world[:renderings] }
    end
  end

  # ── Phase 2 — exploration (one fresh context per subproblem) ────────

  map(:explore, run: :explore_one) do |my|
    my.items = ruby!(:subproblems).value
  end

  # ── Phase 3 — anchor verification (authoritative, Ruby) ─────────────

  ruby(:verified) do
    world = ruby!(:world).value
    findings = collect(map!(:explore)).filter_map { |entry| entry[:finding] }
    verified = findings.map do |f|
      anchors = Array(f['anchors']).map(&:to_s)
      resolved = anchors.map { |a| Runes::Discovery::Anchor.resolved?(a, repo: world[:repo]) }
      {
        'finding' => f,
        'anchors' => anchors,
        'resolved' => resolved,
        # A finding without a resolvable anchor is dropped at verify,
        # never reworded (design §4).
        'anchor_ok' => !anchors.empty? && resolved.all?
      }
    end
    rate = verified.empty? ? 0.0 : verified.count { |v| v['anchor_ok'] }.to_f / verified.size
    { verified: verified, anchor_pass_rate: rate }
  end

  # ── Phase 4 — loop-safety + assembly (Ruby, never the model) ────────

  ruby(:card) do
    world = ruby!(:world).value
    verified = ruby!(:verified).value
    raw_outputs = [chat!(:brief_split).response.to_s] +
                  collect(map!(:explore)).map { |entry| entry[:raw].to_s }
    loop_events = raw_outputs.count { |text| Runes::Discovery::LoopDetector.loop_detected?(text) }

    kept = verified[:verified].select { |v| v['anchor_ok'] }
    dropped = verified[:verified].reject { |v| v['anchor_ok'] }
    subproblems = collect(map!(:explore)).map do |entry|
      sp = entry[:item]['sp']
      fs = kept.select { |v| v['finding']['subproblem_id'] == sp['id'] }
      {
        'id' => sp['id'], 'question' => sp['text'],
        'status' => fs.empty? ? 'unknown' : 'answered',
        'findings' => fs.map { |v| v['finding'] }
      }
    end

    problem = {
      'restatement' => JSON.parse(chat!(:brief_split).response.to_s[/\{.*\}/m].to_s)['restatement'].to_s,
      'success_criteria' => ['every claim in the card has a resolved anchor'],
      'out_of_scope' => []
    }
    meta = {
      'renderings_used' => %w[tree imports tests churn docs],
      'calls' => { 'text' => 1 + collect(map!(:explore)).size, 'd1' => 0 },
      'anchor_pass_rate' => verified[:anchor_pass_rate],
      'loop_events' => loop_events,
      'dropped_findings' => dropped.size,
      'sufficiency' => { 'coverage' => subproblems.empty? ? 0.0 : subproblems.count { |s| s['status'] == 'answered' }.to_f / subproblems.size,
                         'verdict' => subproblems.empty? || subproblems.all? { |s| s['status'] == 'answered' } ? 'sufficient' : 'insufficient' }
    }
    Runes::Discovery::Card.assemble(
      state_id: world[:renderings]['state_id'],
      problem: problem,
      subproblems: subproblems,
      modules: [],
      unknowns: dropped.map { |v| { 'question' => v['finding']['unknown'].to_s, 'why_it_matters' => 'anchor unresolved', 'proposed_probe' => 'read the anchored file' } },
      risks: [],
      mission_seed: { 'proposed_todos' => subproblems.flat_map { |s| s['findings'] }.map { |f| f['finding'].to_s }.first(5),
                      'acceptance_criteria' => [], 'files_touched' => kept.flat_map { |v| v['anchors'] }.map { |a| a.to_s.split(':').first }.uniq,
                      'verification_strategy' => 'anchor resolution' },
      meta: meta,
      out_dir: world[:out_dir]
    )
  end

  outputs do |_scope_value, _scope_index|
    card = ruby!(:card).value
    verified = ruby!(:verified).value
    {
      card: card['card'],
      json_path: card['json_path'],
      md_path: card['md_path'],
      anchor_pass_rate: verified[:anchor_pass_rate],
      loop_events: card['card']['meta']['loop_events'],
      subproblems: card['card']['subproblems'].size
    }
  end
end

# One subproblem, one fresh context, one typed finding. Ruby picks the
# candidate files deterministically (imports + term scan); the model only
# fills the finding.v1 slot.
execute(:explore_one) do
  ruby(:item) { |_my, scope_value, _index| scope_value }

  ruby(:candidates) do
    item = ruby!(:item).value
    sp = item['sp']
    repo = item['repo']
    imports = item['renderings']['imports'] || {}
    terms = sp['text'].to_s.scan(/[a-z_]{4,}/i).map(&:downcase).uniq.first(5)
    candidates = imports.keys.select do |f|
      content = begin
        File.read(File.join(repo, f), 50_000)
      rescue StandardError
        next false
      end
      terms.any? { |t| content.downcase.include?(t) }
    end.first(3)
    { candidates: candidates }
  end

  chat(:finding) do
    item = ruby!(:item).value
    candidates = ruby!(:candidates).value[:candidates]
    span = if candidates.first
             begin
               File.read(File.join(item['repo'], candidates.first), 4_000)
             rescue StandardError
               'unreadable'
             end
           else
             'no candidate file'
           end
    <<~PROMPT
      Subproblem: #{item['sp']['text']}
      File: #{candidates.first || 'none'} (trimmed span):
      #{span}

      State what this code does that answers the subproblem, with an anchor
      "path:start-end". Symbols must match defined names exactly. If the span
      does not answer it, output {"finding": null, "unknown": "..."}.
      Never invent an anchor. Max 200 tokens.
      Output JSON only:
      {"subproblem_id": "#{item['sp']['id']}", "finding": "...", "anchors": ["path:1-10"], "confidence": "grounded|partial|guess", "unknowns": []}
    PROMPT
  end

  ruby(:parsed) do
    raw = chat!(:finding).response.to_s
    json = begin
      JSON.parse(raw[/\{.*\}/m].to_s)
    rescue JSON::ParserError, TypeError
      nil
    end
    { item: ruby!(:item).value, raw: raw, finding: json }
  end

  outputs { |_scope_value, _scope_index| ruby!(:parsed).value }
end
