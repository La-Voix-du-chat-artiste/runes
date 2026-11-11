# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/runes'
require 'tmpdir'
require 'fileutils'
require 'json'

# The pre-swarm discovery phase (docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md):
# deterministic renderings, the loop detector, mechanical anchor resolution,
# the discovery.v1/finding.v1 schemas — and the workflow prototype
# examples/discover_codebase.rb run end to end offline with the provider seam
# scripted, so the example cannot rot.
class DiscoveryTest < Minitest::Test
  EXAMPLE = File.expand_path('../examples/discover_codebase.rb', __dir__)

  def setup
    @repo = Dir.mktmpdir('runes-discovery-repo')
    FileUtils.mkdir_p(File.join(@repo, 'lib', 'runes'))
    File.write(File.join(@repo, 'lib', 'runes', 'ledger.rb'), <<~RUBY)
      module Runes
        class RequestLedger
          def claim(request_id)
            true
          end
        end
      end
    RUBY
    File.write(File.join(@repo, 'lib', 'runes', 'broker.rb'), <<~RUBY)
      module Runes
        class Broker
          def run
            :ok
          end
        end
      end
    RUBY
    FileUtils.mkdir_p(File.join(@repo, 'test'))
    File.write(File.join(@repo, 'test', 'ledger_test.rb'), "def test_claim\nend\n")
    File.write(File.join(@repo, 'README.md'), "# fixture repo\n")
    @out = Dir.mktmpdir('runes-discovery-out')
  end

  def teardown
    FileUtils.remove_entry(@repo, true) if @repo && Dir.exist?(@repo)
    FileUtils.remove_entry(@out, true) if @out && Dir.exist?(@out)
    Runes::Plugins::Chat.reset_backend!
    %w[RUNES_DISCOVERY_REPO RUNES_DISCOVERY_OUT RUNES_DISCOVERY_BRIEF].each { |k| ENV.delete(k) }
  end

  # ------------------------------------------------------------ unit tests

  def test_loop_detector_flags_repeated_windows
    looping = (['alpha beta gamma delta epsilon zeta eta theta'] * 8).join(' ')
    assert Runes::Discovery::LoopDetector.loop_detected?(looping)

    normal = (1..200).map { |i| "word#{i}" }.join(' ')
    refute Runes::Discovery::LoopDetector.loop_detected?(normal)

    # degenerate window (all tokens equal) must not flag
    degenerate = (['same'] * 100).join(' ')
    refute Runes::Discovery::LoopDetector.loop_detected?(degenerate)

    refute Runes::Discovery::LoopDetector.loop_detected?('short text')
  end

  def test_anchor_parse_and_resolve
    assert_equal({ 'path' => 'lib/runes/ledger.rb', 'start' => 3, 'end' => 5 },
                 Runes::Discovery::Anchor.parse('lib/runes/ledger.rb:3-5'))
    assert_equal({ 'path' => 'lib/runes/ledger.rb', 'symbol' => 'RequestLedger' },
                 Runes::Discovery::Anchor.parse('lib/runes/ledger.rb:RequestLedger'))
    assert_nil Runes::Discovery::Anchor.parse('not an anchor')

    assert Runes::Discovery::Anchor.resolved?('lib/runes/ledger.rb:1-7', repo: @repo)
    refute Runes::Discovery::Anchor.resolved?('lib/runes/ledger.rb:1-999', repo: @repo)
    refute Runes::Discovery::Anchor.resolved?('../etc/passwd:1-2', repo: @repo)
    assert Runes::Discovery::Anchor.resolved?('lib/runes/ledger.rb:RequestLedger', repo: @repo)
    refute Runes::Discovery::Anchor.resolved?('lib/runes/ledger.rb:NoSuchSymbol', repo: @repo)
  end

  def test_renderings_are_deterministic_views_of_one_state
    brief = 'Add a kanban board'
    r1 = Runes::Discovery::Renderings.build(repo: @repo, brief: brief)
    r2 = Runes::Discovery::Renderings.build(repo: @repo, brief: brief)
    assert_equal r1, r2, 'same repo + brief => identical renderings'
    assert_includes r1['state_id'], 'brief:'
    assert r1['tree'].key?('lib/runes')
    assert_includes r1['tests'], 'test/ledger_test.rb'
    assert_includes r1['docs'], 'README.md'
    assert r1['imports'].key?('lib/runes/ledger.rb')
    assert r1['churn'].is_a?(Array)
  end

  def test_schemas_reject_bad_findings_and_cards
    assert_empty Runes::Discovery::Schemas.finding_errors(
      'subproblem_id' => 'S1', 'finding' => 'x', 'anchors' => ['a.rb:1-2'], 'confidence' => 'grounded'
    )
    refute_empty Runes::Discovery::Schemas.finding_errors('subproblem_id' => 'S1')
    refute_empty Runes::Discovery::Schemas.finding_errors(
      'subproblem_id' => 'S1', 'finding' => 'x', 'anchors' => [], 'confidence' => 'wild'
    )
    assert_empty Runes::Discovery::Schemas.card_errors(
      'state_id' => 's', 'problem' => {}, 'subproblems' => [], 'meta' => {}
    )
    refute_empty Runes::Discovery::Schemas.card_errors('state_id' => 's')
  end

  def test_contract_diff_schemas_reasons_and_hops
    assert_includes Runes::Swarm::Capacity::SCHEMAS, 'discovery.v1'
    assert_includes Runes::Swarm::Capacity::SCHEMAS, 'finding.v1'
    %i[discovery_insufficient anchor_unresolved loop_detected].each do |reason|
      assert_includes Runes::Swarm::Decision::REASONS, reason
    end
    assert_includes Runes::Swarm::Decision::HOPS, :discoverer
    # and they build real decisions
    d = Runes::Swarm::Decision.new(status: :decline, reason_code: :loop_detected, body: '')
    assert_equal :loop_detected, d.reason_code
  end

  # ------------------------------------------------------- end to end (offline)

  class ScriptedChat
    attr_reader :prompts

    def initialize(loop: false)
      @prompts = []
      @loop = loop
    end

    def chat(prompt:, session:, config:)
      @prompts << prompt
      response =
        if prompt.include?('Restate this task')
          JSON.generate('restatement' => 'Add a kanban board to the observatory',
                        'subproblems' => [
                          { 'id' => 'S1', 'text' => 'Where does the ledger dedupe requests', 'needs_codebase' => true },
                          { 'id' => 'S2', 'text' => 'How does the broker run', 'needs_codebase' => true }
                        ])
        elsif @loop
          (['alpha beta gamma delta epsilon zeta eta theta'] * 8).join(' ')
        else
          JSON.generate('subproblem_id' => (prompt.include?('ledger') ? 'S1' : 'S2'),
                        'finding' => 'RequestLedger.claim dedupes by request_id',
                        'anchors' => ['lib/runes/ledger.rb:3-6'],
                        'confidence' => 'grounded', 'unknowns' => [])
        end
      Runes::Plugins::Chat::Reply.new(response: response,
                                      messages: [{ role: 'user', content: prompt }, { role: 'assistant', content: response }],
                                      model: 'scripted', input_tokens: 5, output_tokens: 9)
    end
  end

  def run_example(loop: false)
    ENV['RUNES_DISCOVERY_REPO'] = @repo
    ENV['RUNES_DISCOVERY_OUT'] = @out
    ENV['RUNES_DISCOVERY_BRIEF'] = 'Add a kanban board to the observatory'
    chat = ScriptedChat.new(loop: loop)
    Runes::Plugins::Chat.backend = chat
    workflow = nil
    capture_io { workflow = Runes::Workflow.from_file(EXAMPLE, Runes::WorkflowParams.new([], [], {})) }
    [workflow.final_output, chat]
  end

  def test_the_example_runs_offline_and_writes_a_valid_anchored_card
    output, chat = run_example

    json_path = File.join(@out, 'discovery.json')
    md_path = File.join(@out, 'discovery_card.md')
    assert File.file?(json_path), 'discovery.json must be written'
    assert File.file?(md_path), 'discovery_card.md must be written'

    card = JSON.parse(File.read(json_path))
    assert_equal 'discovery.v1', card['schema']
    assert_empty Runes::Discovery::Schemas.card_errors(card)
    assert_includes card['state_id'], 'brief:'
    assert_equal 2, card['subproblems'].size
    assert_equal 1.0, card['meta']['anchor_pass_rate'], 'the scripted anchor resolves'
    assert_equal 0, card['meta']['loop_events']
    assert_equal 'sufficient', card['meta']['sufficiency']['verdict']
    assert_includes File.read(md_path), 'Discovery card'

    assert_equal json_path, output[:json_path]
    assert_equal 1.0, output[:anchor_pass_rate]
    assert_equal 2, output[:subproblems]
    assert chat.prompts.any? { |p| p.include?('Restate this task') }
    assert chat.prompts.any? { |p| p.include?('Subproblem:') }
  end

  def test_loop_detector_counts_loop_events_in_the_receipt
    output, = run_example(loop: true)
    assert_operator output[:loop_events], :>=, 1, 'a looping model output must be counted as a loop_event'
  end
end
