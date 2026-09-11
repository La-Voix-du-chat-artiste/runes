# frozen_string_literal: true

require "timeout"
require_relative "test_helper"
require_relative "../lib/runes/workflow"

# The flagship example, run for real — offline, in about a second.
#
# This is what keeps `examples/prospect_pipeline.rb` honest: the file the docs
# point at is the file this suite executes end to end, with the provider seam
# scripted. If the DSL changes shape, or the kanban format drifts, or a step
# stops threading its input, this fails.
class ProspectPipelineTest < Minitest::Test
  EXAMPLE = File.expand_path("../examples/prospect_pipeline.rb", __dir__)
  GOAL = "## Objectif\nFormer trois partenaires intégrateurs d'ici la fin du trimestre."
  TODOS = {
    "mission" => "Former 3 partenaires",
    "todos" => [
      { "title" => "Lister 50 PME cibles", "assignee" => "Jean Dupont" },
      { "title" => "Préparer le kit de démo", "assignee" => "Marie Martin" }
    ]
  }.freeze

  # Answers each rune's prompt by what it asks for — and decides a verdict from
  # the todo's title, so the run exercises both a pass and a fail.
  class ScriptedAgent
    attr_reader :prompts

    def initialize(fail_titles: ["Préparer le kit de démo"], plan: nil)
      @prompts = []
      @fail_titles = fail_titles
      @plan = plan
    end

    def invoke(input)
      prompt = Array(input.prompts).last.to_s
      @prompts << prompt

      Runes::Plugins::Agent::Output.new(response: respond_to_prompt(prompt),
                                       session: "scripted",
                                       stats: Runes::Plugins::Agent::Stats.new)
    end

    private

    def respond_to_prompt(prompt)
      case prompt
      when /brainstorming half/ then GOAL
      when /Break this goal into between/ then (@plan || JSON.generate(TODOS))
      when /You are the verifier/ then verdict_for(prompt)
      when /Execute this todo/ then "Fait : la liste est dans crm/cibles.md (50 lignes)."
      when /short, specific outreach message/ then "Bonjour,\n\nUn mot court et concret."
      else raise "unexpected prompt: #{prompt[0, 100].inspect}"
      end
    end

    def verdict_for(prompt)
      todo = prompt[/TODO: (.*)/, 1].to_s
      if @fail_titles.any? { |title| todo.include?(title) }
        JSON.generate("verdict" => "fail", "reason" => "le kit de démo n'est pas montrable")
      else
        JSON.generate("verdict" => "pass", "reason" => "50 cibles vérifiées")
      end
    end
  end

  class ScriptedChat
    attr_reader :prompts

    def initialize = @prompts = []

    def chat(prompt:, session:, config:)
      @prompts << prompt
      Runes::Plugins::Chat::Reply.new(
        response: "• Deux cibles prioritaires\n• Un brouillon prêt\n• Relancer Marie",
        messages: [{ role: "user", content: prompt }, { role: "assistant", content: "ok" }],
        model: "scripted", input_tokens: 5, output_tokens: 9
      )
    end
  end

  def setup
    @root = Dir.mktmpdir("runes-prospect-")
    @agent = ScriptedAgent.new
    @chat = ScriptedChat.new
    @env = ENV["PROSPECT_ROOT"]
    ENV["PROSPECT_ROOT"] = @root
    Runes::Plugins::Agent.provider_factory = ->(_config) { @agent }
    Runes::Plugins::Chat.backend = @chat
  end

  def teardown
    Runes::Plugins::Agent.reset_seams!
    Runes::Plugins::Chat.reset_backend!
    @env.nil? ? ENV.delete("PROSPECT_ROOT") : ENV["PROSPECT_ROOT"] = @env
    FileUtils.remove_entry(@root, true) if @root && Dir.exist?(@root)
  end

  def test_the_whole_pipeline_runs_offline_and_leaves_the_artifacts_it_promises
    output = run_pipeline

    # 1. the epic: a real code, referencing itself in prose
    goal_path = Dir.glob(File.join(@root, "epics", "*", "goal.md")).first
    refute_nil goal_path, "goal.md must be written"
    goal = File.read(goal_path)
    assert_includes goal, "#E-001"
    assert_includes goal, "Former trois partenaires"

    # 2. the mission: their kanban format, both verdicts applied, reasons kept
    mission_path = Dir.glob(File.join(@root, "epics", "*", "missions", "*.mmd")).first
    refute_nil mission_path, "the mission .mmd must be written"
    text = File.read(mission_path)
    assert_empty Runes::Kanban.validate(text), "the file must satisfy their validator: #{text}"
    parsed = Runes::Kanban.parse(text)
    assert_equal "M-001", parsed[:header]["code"]
    assert_equal "Blocked", parsed[:header]["status"],
                 "one blocked todo means the mission is blocked, not done"
    assert_equal ["Lister 50 PME cibles — pass: 50 cibles vérifiées"],
                 parsed[:columns]["done"].map(&:title)
    assert_equal ["Préparer le kit de démo — fail: le kit de démo n'est pas montrable"],
                 parsed[:columns]["blocked"].map(&:title)
    assert_empty parsed[:columns]["todo"]

    # 3. the CRM leg: a deterministic rule, then a human-in-the-loop draft
    people = JSON.parse(File.read(File.join(@root, "crm", "people.json")))
    assert_equal 3, people.size
    drafts = Dir.glob(File.join(@root, "crm", "outbox", "*.md"))
    assert_equal 2, drafts.size, "the two most silent contacts get a draft"
    assert_includes File.read(drafts.first), "non envoyé"

    # 4. the report, and the run's own receipts
    report = File.read(File.join(@root, "crm", "weekly-report.md"))
    assert_includes report, "Ce qui a bougé"
    assert_includes report, "le kit de démo n'est pas montrable"
    assert_includes report, "## À faire ensuite"

    assert_equal 2, output[:todos]
    assert_equal %w[pass fail], output[:advanced].map { |todo| todo[:verdict] }
    assert_equal 2, output[:drafts].size
    assert_equal 3, output[:next_actions].size
    assert_equal File.join(@root, "crm", "weekly-report.md"), output[:report_path]
  end

  def test_the_prompts_ask_the_questions_the_pipeline_needs
    run_pipeline

    joined = @agent.prompts.join("\n---\n")
    assert_match(/brainstorming half/, joined)
    assert_match(/Break this goal into between three and six todos/, joined)
    assert_match(/You are the verifier/, joined)
    assert_match(/short, specific outreach message/, joined)
    assert_equal 1, @chat.prompts.size, "the report asks for exactly one summary"
    assert_match(/what moved, what is stuck/, @chat.prompts.first)
  end

  def test_a_plan_that_cannot_be_parsed_fails_loudly_instead_of_writing_an_empty_mission
    @agent = ScriptedAgent.new(plan: "I could not decide, sorry.")

    error = assert_raises(Runes::ControlFlow::FailCog) { run_pipeline }

    assert_includes error.message.to_s, "unparseable todos"
    assert_empty Dir.glob(File.join(@root, "epics", "*", "missions", "*.mmd")),
                 "a failed plan must not leave a mission behind"
  end

  # Codes are minted from what is already on disk, and — like the app this
  # format comes from — mission codes are per-epic (`#M-001` in each), while
  # epic codes are global.
  def test_running_twice_mints_the_next_epic_code_and_keeps_the_history
    run_pipeline
    run_pipeline(idea: "Deuxième idée")

    codes = Dir.glob(File.join(@root, "epics", "*", "goal.md")).map { |path| File.read(path)[/#E-\d+/] }
    assert_equal ["#E-001", "#E-002"], codes.sort

    missions = Dir.glob(File.join(@root, "epics", "*", "missions", "*.mmd"))
    assert_equal 2, missions.size
    assert_equal ["M-001"], missions.map { |path| File.read(path)[/M-\d+/] }.uniq
  end

  private

  def run_pipeline(idea: "Former trois partenaires intégrateurs")
    workflow = nil
    capture_io do
      workflow = Runes::Workflow.from_file(EXAMPLE, Runes::WorkflowParams.new([], [], { idea: idea }))
    end
    workflow.final_output
  end
end
