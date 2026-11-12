# frozen_string_literal: true

# The discovery-phase benchmark (design §7): three arms over
# examples/discover_codebase.rb, run against a local MLX checkpoint through
# the chat seam — no cloud key needed.
#
#   ruby bench/discovery/run.rb \
#     --repo /path/to/repo --brief "..." --python tmp/venv-swarm/bin/python \
#     --model LiquidAI/LFM3-1.7B-MLX-4bit --out bench/discovery/results/2026-11-12-discovery.json
#
# Arms:
#   full      renderings + explore + verify (the example as-is)
#   tree-only repo-map control: RUNES_DISCOVERY_VIEWS=tree, zero exploration
#   external  one external call — only if an endpoint is configured
#             (RUNES_DISCOVERY_EXTERNAL_BASE_URL + _MODEL); otherwise the arm
#             is recorded as infra, exactly like frontier-1x in the swarm bench.
#
# Metrics per arm: anchor_pass_rate, loop_events, text calls, subproblem
# coverage, and the card's sufficiency verdict. The downstream metric
# (mission acceptance in /build) is out of scope here — the card quality
# numbers are the exploration-modality lift the swarm pilots could not produce.
require 'json'
require 'optparse'
require 'open3'
require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'runes'

module Runes
  module Bench
    module Discovery
      # A chat backend that shells out to the local LFM3 CLI — the same seam
      # the swarm bench uses, so the discovery benchmark needs no cloud key.
      class LocalMlxChat
        def initialize(model:, python:, cli:, max_tokens: 320)
          @model = model
          @python = python
          @cli = cli
          @max_tokens = max_tokens
          @calls = 0
        end

        attr_reader :calls

        def chat(prompt:, session:, config:)
          @calls += 1
          out, err, status = Open3.capture3(
            @python, @cli, '--model', @model, '--max-tokens', @max_tokens.to_s,
            '--temperature', '0.1', '--top-k', '50', '--repetition-penalty', '1.1',
            stdin_data: prompt.to_s
          )
          response = status.success? ? out.strip.force_encoding('UTF-8').scrub : "{\"error\": #{err.strip[0, 200].inspect}}"
          Runes::Plugins::Chat::Reply.new(
            response: response,
            messages: [{ role: 'user', content: prompt.to_s }, { role: 'assistant', content: response }],
            model: @model, input_tokens: prompt.to_s.length / 4, output_tokens: response.length / 4
          )
        end
      end

      class Runner
        def self.run(argv)
          options = {
            repo: Dir.pwd, brief: 'Describe this codebase and propose one improvement.',
            python: 'python3', model: 'LiquidAI/LFM3-1.7B-MLX-4bit',
            cli: File.expand_path('../../bench/swarm/lfm3_cli.py', __dir__),
            out: File.expand_path('results/discovery.json', __dir__),
            external_base_url: ENV['RUNES_DISCOVERY_EXTERNAL_BASE_URL'],
            external_model: ENV['RUNES_DISCOVERY_EXTERNAL_MODEL']
          }
          OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/discovery/run.rb --repo DIR --brief "..." [--python P] [--model M] [--out PATH]'
            opts.on('--repo DIR') { |v| options[:repo] = v }
            opts.on('--brief TEXT') { |v| options[:brief] = v }
            opts.on('--python P') { |v| options[:python] = v }
            opts.on('--model M') { |v| options[:model] = v }
            opts.on('--out PATH') { |v| options[:out] = v }
            opts.on('-h', '--help') { puts opts; exit 0 }
          end.parse!(argv)

          new(**options).run
        end

        def initialize(repo:, brief:, python:, model:, cli:, out:, external_base_url:, external_model:)
          @repo = File.expand_path(repo)
          @brief = brief
          @python = python
          @model = model
          @cli = cli
          @out = out
          @external_base_url = external_base_url
          @external_model = external_model
        end

        def run
          arms = {}
          arms['full'] = run_arm('full', {})
          arms['tree-only'] = run_arm('tree-only', 'RUNES_DISCOVERY_VIEWS' => 'tree')
          arms['external'] = run_external_arm

          report = {
            'benchmark' => 'discovery-phase-v1',
            'date' => Time.now.utc.strftime('%Y-%m-%d'),
            'repo' => @repo,
            'brief' => @brief,
            'model' => @model,
            'arms' => arms
          }
          FileUtils.mkdir_p(File.dirname(@out))
          File.write(@out, JSON.pretty_generate(report) + "\n")
          puts "wrote #{@out}"
          arms.each do |name, arm|
            next if arm['infra']

            puts format('%-10s anchor_pass=%.2f loop_events=%d calls=%d coverage=%.2f verdict=%s',
                        name, arm['anchor_pass_rate'], arm['loop_events'], arm['text_calls'],
                        arm['coverage'], arm['sufficiency_verdict'])
          end
          report
        end

        private

        def run_arm(name, env)
          out_dir = File.join(Dir.mktmpdir("discovery-#{name}-"), 'out')
          chat = LocalMlxChat.new(model: @model, python: @python, cli: @cli)
          Runes::Plugins::Chat.backend = chat
          full_env = {
            'RUNES_DISCOVERY_REPO' => @repo,
            'RUNES_DISCOVERY_OUT' => out_dir,
            'RUNES_DISCOVERY_BRIEF' => @brief
          }.merge(env)
          old = full_env.keys.to_h { |k| [k, ENV[k]] }
          full_env.each { |k, v| ENV[k] = v }
          output = nil
          begin
            capture_io do
              workflow = Runes::Workflow.from_file(
                File.expand_path('../../examples/discover_codebase.rb', __dir__),
                Runes::WorkflowParams.new([], [], {})
              )
              output = workflow.final_output
            end
          ensure
            old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
            Runes::Plugins::Chat.reset_backend!
          end
          card = output[:card] || {}
          meta = card['meta'] || {}
          {
            'arm' => name,
            'anchor_pass_rate' => output[:anchor_pass_rate],
            'loop_events' => output[:loop_events],
            'text_calls' => chat.calls,
            'subproblems' => output[:subproblems],
            'coverage' => meta.dig('sufficiency', 'coverage'),
            'sufficiency_verdict' => meta.dig('sufficiency', 'verdict'),
            'json_path' => output[:json_path]
          }
        end

        def run_external_arm
          if @external_base_url.to_s.empty? || @external_model.to_s.empty?
            return { 'arm' => 'external', 'infra' => true,
                     'error' => 'no endpoint configured (RUNES_DISCOVERY_EXTERNAL_BASE_URL/_MODEL)' }
          end
          # One external call with the brief + tree rendering; recorded for
          # the honest comparison the design asks for.
          require 'net/http'
          tree = Runes::Discovery::Renderings.build(repo: @repo, brief: @brief)['tree']
          uri = URI("#{@external_base_url}/chat/completions")
          req = Net::HTTP::Post.new(uri)
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(
            model: @external_model,
            messages: [{ role: 'user', content: "#{@brief}\n\nRepo tree:\n#{JSON.generate(tree)}" }]
          )
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
          { 'arm' => 'external', 'status' => res.code, 'text_calls' => 1 }
        rescue StandardError => e
          { 'arm' => 'external', 'infra' => true, 'error' => "#{e.class}: #{e.message}" }
        end

        def capture_io
          require 'stringio'
          orig = $stdout
          $stdout = StringIO.new
          yield
        ensure
          $stdout = orig
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit(Runes::Bench::Discovery::Runner.run(ARGV) ? 0 : 2)
end
