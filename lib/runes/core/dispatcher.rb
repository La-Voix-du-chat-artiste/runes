require 'json'
require 'mqtt'
require 'open3'
require 'securerandom'
require 'fileutils'
require 'socket'
require 'digest'

require_relative '../mqtt/broker'
require_relative '../wasm/vm_manager'
require_relative '../capabilities/guard'
require_relative 'settings'
require_relative 'llm_client'
require_relative 'plan_parser'
require_relative 'json_scan'
require_relative 'tool_registry'
require_relative '../version'
require_relative '../transport'
require_relative '../a2a'
require_relative '../security'
require_relative '../fleet'
require_relative '../guard_telemetry_sink'
require_relative '../request_ledger'
require_relative '../agent/fabric'
require_relative '../agent/journal'
require_relative '../agent/session_store'

module Runes
  module Core
    # The dispatcher listens on `runes/prompts` for user prompts, asks the
    # planner LLM to decompose each prompt into a sequence of tool calls,
    # executes the calls (safely, with workspace confinement and a
    # capability guard), then publishes a summary back to
    # `runes/prompts/response`.
    #
    # Reactive-fabric features (see Runes.rtf):
    #   * Publishes a retained Agent Card on `runes/agents/<id>/card` at
    #     boot, so other dispatchers and observability tools can discover
    #     it without polling.
    #   * Sets a Last Will on `runes/agents/<id>/status` so unexpected
    #     crashes flip the LWT and the fleet knows.
    #   * Streams per-step progress on `runes/prompts/<request_id>/progress`
    #     as the plan executes.
    class Dispatcher
      include Runes::Agent::Fabric
      include Runes::Agent::Journal
      include Runes::Agent::SessionStore

      PROMPT_TOPIC      = 'runes/prompts'.freeze
      RESPONSE_TOPIC    = 'runes/prompts/response'.freeze
      PROMPT_LOG_TOPIC  = 'runes/_log/prompts'.freeze
      TASK_PATTERN      = %r{\Arunes/agents/([^/]+)/tasks\z}.freeze
      TASK_REPLY_PATTERN = %r{\Arunes/agents/([^/]+)/tasks/([^/]+)/response\z}.freeze
      TOOL_REQ_PATTERN  = %r{\Arunes/tools/([^/]+)/request\z}.freeze

      # Shared-subscription group that consumes `runes/prompts`. Every agent
      # joins the same group, so the BROKER picks exactly one member per
      # prompt — this is what replaced the claim/lease protocol.
      DEFAULT_PROMPT_GROUP = 'runes-prompts'.freeze

      MODES             = %w[build goal plan mission].freeze

      BUILTIN_TOOLS = %w[write_file read_file run_command].freeze

      # One shared command-policy checker for the dispatcher and
      # bin/runes-mcp (S5-2/E5-11); these constants are kept as
      # test-visible aliases of the module's tables.
      DANGEROUS_COMMAND_PATTERNS = Runes::Security::CommandPolicy::DANGEROUS_COMMAND_PATTERNS
      SHELL_INJECTION_CHARS = Runes::Security::CommandPolicy::SHELL_METACHARACTERS

      DEFAULT_CMD_TIMEOUT_S  = 10
      DEFAULT_OUTPUT_CAP     = 64 * 1024 # bytes of combined stdout+stderr
      MAX_PLAN_STEPS         = 25
      MAX_PROMPT_BYTES       = 32 * 1024
      DEFAULT_READ_CAP       = 1024 * 1024 # bytes returned by read_file
      DEFAULT_WRITE_CAP      = 1024 * 1024 # bytes accepted by write_file
      DEFAULT_MAX_CONCURRENT = 4
      DEFAULT_MAX_TOOL_CONCURRENT = 2
      # Bounded backlog for the prompt worker pool: at the cap new work is
      # refused with a visible busy reply, never executed inline (B4-3).
      QUEUE_FACTOR           = 4
      REQUEST_ID_RE          = /\A[A-Za-z0-9_-]{1,32}\z/.freeze
      AGENT_ID_RE            = /\A[A-Za-z0-9_.-]{1,64}\z/.freeze

      # Bound the A2A peer registry (cards are retained, so peers arrive
      # without being asked for).
      MAX_PEERS = 256

      # Constants that stay defined here but are referenced by the
      # extracted mixins: unqualified lookup inside those modules uses
      # their own lexical scope, so mirror them into the module namespace.
      Runes::Agent::Fabric.const_set(:PROMPT_TOPIC, PROMPT_TOPIC)
      Runes::Agent::Fabric.const_set(:DEFAULT_PROMPT_GROUP, DEFAULT_PROMPT_GROUP)
      Runes::Agent::Fabric.const_set(:MAX_PEERS, MAX_PEERS)
      Runes::Agent::Fabric.const_set(:AGENT_ID_RE, AGENT_ID_RE)
      Runes::Agent::Fabric.const_set(:REQUEST_ID_RE, REQUEST_ID_RE)
      Runes::Agent::Fabric.const_set(:TASK_REPLY_PATTERN, TASK_REPLY_PATTERN)
      Runes::Agent::Fabric.const_set(:BUILTIN_TOOLS, BUILTIN_TOOLS)
      Runes::Agent::Journal.const_set(:PROMPT_LOG_TOPIC, PROMPT_LOG_TOPIC)

      # Test-visible alias: the constant now lives on the Journal mixin.
      JOURNAL_ROTATE_BYTES = Runes::Agent::Journal::JOURNAL_ROTATE_BYTES


      attr_reader :agent_id

      # `transport:` is the seam: inject an in-process hub in tests, let
      # the default build an MQTT adapter, or pass Transport.auto for
      # broker probing. Nothing else in the harness knows about MQTT.
      def initialize(broker_config = nil, wasm_path = nil, ui = nil,
                     settings: nil,
                     agent_id: nil,
                     tool_registry: nil,
                     transport: nil,
                     request_ledger: nil,
                     fleet: nil)
        @broker_config = broker_config || {}
        @ui = ui
        @settings = settings || Runes::Core::Settings.new
        @workspace = @settings.workspace_root
        FileUtils.mkdir_p(@workspace)
        # Optional fleet file (0.4.0): loaded after connect, rules run on
        # this agent's transport, journal persisted under settings.root.
        @fleet_path = fleet

        @agent_id = agent_id.nil? ? default_agent_id : validate_agent_id!(agent_id)
        # S5-4: accepted tool-RPC nonces (replay window), created lazily
        # when RPC is enabled.
        @rpc_nonces = nil
        # Inbound dedupe: distribution is exactly-once via shared
        # subscriptions, but redelivery/retries could run one request twice
        # (lib/runes/request_ledger.rb). Injectable for tests.
        @request_ledger = request_ledger || Runes::RequestLedger.new
        @llm = Runes::Core::LLMClient.new(@settings)
        @vm_manager = Runes::WASM::VMManager.new(
          wasm_path || File.join(@settings.root, 'ruby.wasm'),
          backend: :auto,
          workspace: @workspace,
          settings: @settings
        )

        @registry = tool_registry || Runes::Core::ToolRegistry.new(
          tools_dir: File.join(@settings.root, 'tools')
        )
        @guard = Runes::Capabilities::Guard.new(
          policy_file_path,
          additional_fragments: [@registry.policy_fragment]
        )
        @plan_parser = Runes::Core::PlanParser.new
        @in_flight = 0
        @in_flight_mutex = Mutex.new
        @tool_in_flight = 0
        @tool_in_flight_mutex = Mutex.new
        @journal_mutex = Mutex.new
        @work_queue = SizedQueue.new(queue_capacity)
        @workers = []
        @stopping = false
        # A2A identity + discovery
        @a2a_org = @settings.env('RUNES_A2A_ORG') || 'runes'
        @a2a_unit = @settings.env('RUNES_A2A_UNIT') || Socket.gethostname
        @peers = {}
        @peers_mutex = Mutex.new
        @transport = transport
        # Refusals belong on the fabric, not only in this process's log: the
        # observer can show what was blocked only if someone publishes it
        # (doc5.md O2.3). A sink someone already set (a test, the workflow CLI)
        # wins — GuardTelemetry.attach never overrides it.
        Runes::GuardTelemetry.attach(transport: @transport, agent_id: @agent_id) if @transport
        # Optional message signing (P1.5): OFF by default. When enabled,
        # inbound envelopes must carry a valid signature from a trusted key
        # and outbound delegation envelopes are signed.
        @require_signatures = %w[1 true yes on].include?(@settings.env('RUNES_REQUIRE_SIGNATURES').to_s.downcase)
        # Stricter sibling: refuse envelopes that carry no ts/nonce, so replay
        # protection cannot be skipped by omitting the fields (doc5.md S5-4).
        @require_freshness = %w[1 true yes on].include?(@settings.env('RUNES_REQUIRE_FRESHNESS').to_s.downcase)
        if @require_signatures
          @identity = Runes::Security::Identity.load_or_create(agent_id: @agent_id)
          @trust_store = Runes::Security::TrustStore.load_dir(trust_dir)
          warn "[Dispatcher] message signing REQUIRED (identity #{@identity.fingerprint[0, 16]}…, " \
               "#{@trust_store.agent_ids.size} trusted peer(s) from #{trust_dir})"
        end
        # goal/plan mode state
        @sessions = {}
        @sessions_mutex = Mutex.new
        @latest_epic = load_latest_epic
        @latest_mission = load_latest_mission
      end

      # X5-2: the agent id becomes an MQTT topic fragment, an A2A segment
      # and a file name. Validate it where it is created (fail fast), not
      # where it is used. An invalid id used to be normalized to a
      # different A2A segment (one agent -> two observer rows) or to an
      # unclassifiable legacy card topic (an id containing `/`).
      def validate_agent_id!(candidate)
        id = candidate.to_s
        return id if id.match?(AGENT_ID_RE)

        raise ArgumentError,
              "invalid agent id #{candidate.inspect} (expected #{AGENT_ID_RE.source} — " \
              'letters, digits, _ . - only, max 64 chars)'
      end

      # The generated default id is sanitized rather than validated: a
      # hostname outside the alphabet (or longer than 64 bytes) must not
      # stop a fresh daemon from booting.
      def default_agent_id
        raw = "runes-#{Socket.gethostname}-#{Process.pid}"
        id = raw.gsub(/[^A-Za-z0-9_.-]/, '-')[0, 64]
        id = "runes-#{Process.pid}" if id.empty?
        id
      end

      # ---------- lifecycle ----------

      def start
        @transport ||= Runes::Transport.build(settings: @settings,
                                               client_id: @agent_id,
                                               host: @broker_config[:host],
                                               port: @broker_config[:port],
                                               will: [agent_status_topic, 'offline', true, 1])
        log "Starting as agent #{@agent_id} (transport: #{@transport.describe})"
        @transport.connect unless @transport.connected?
        log "Connected to broker (#{@transport.describe})."
        subscribe_topics
        start_workers
        announce_agent_card
        log "Workspace: #{@workspace}"
        start_fleet if @fleet_path
        log 'Subscribed. Entering reactive loop (transport threads feed the worker pool).'
        wait_for_shutdown
      end

      def stop
        @stopping = true
      end

      # Transports deliver on their own reader threads, so the agent parks
      # here until interrupted. (The old design owned the MQTT receive loop.)
      def wait_for_shutdown
        sleep 0.2 until @stopping
      rescue Interrupt
        nil
      ensure
        # The fleet runner unsubscribes its rule topics before the
        # transport goes away, and closes its journal file.
        begin
          @fleet_runner&.stop
        rescue StandardError => e
          log "Fleet shutdown error: #{e.class}: #{e.message}"
        end
        @transport&.disconnect
        log 'Stopped.'
      end

      # Fleet layer (0.4.0): load the world fail-closed, run its rules on
      # this agent's transport with a JSONL journal under settings.root.
      # A bad fleet file is loud in the log and leaves nothing half-wired
      # (the loader's atomicity guarantee, §10).
      def start_fleet
        world = Runes::Fleet.load_file(@fleet_path)
        journal_path = File.join(@settings.root, 'log', "fleet-#{world.name}-journal.jsonl")
        @fleet_runner = Runes::Fleet::Runner.new(
          world,
          transport: @transport,
          journal_path: journal_path,
          notifier: ->(n) { log "[fleet] #{n['level']}: #{n['text']}" }
        )
        @fleet_runner.start
        log "Fleet loaded: #{world.name} — #{world.rules.size} rule(s), " \
            "#{world.roles.size} role(s), digest #{world.fingerprint[0, 12]}…"
        log "Fleet journal: #{journal_path}"
      rescue Runes::Fleet::LoadError => e
        log "Fleet load FAILED — no fleet wired: #{e.message}"
      end

      def tool_rpc_enabled?
        %w[1 true yes on].include?(@settings.env('RUNES_TOOL_RPC').to_s.downcase)
      end

      def rpc_secret
        @rpc_secret ||= begin
          configured = @settings.env('RUNES_RPC_SECRET').to_s
          if configured.empty?
            warn '[Dispatcher] RUNES_TOOL_RPC is enabled without RUNES_RPC_SECRET — ' \
                 'generating an ephemeral secret; only in-process callers can use the RPC path'
            SecureRandom.hex(24)
          else
            configured
          end
        end
      end

      # Fixed prompt worker pool (B4-3/E4-3). Transport threads only record
      # and route; workers do the LLM calls and tool runs.
      def start_workers
        return unless @workers.empty?

        max_concurrent_prompts.times do
          @workers << Thread.new do
            loop do
              job = @work_queue.pop
              break if job == :stop
              @in_flight_mutex.synchronize { @in_flight += 1 }
              begin
                job.call
              rescue => e
                log "Prompt worker error: #{e.class}: #{e.message}"
              ensure
                @in_flight_mutex.synchronize { @in_flight -= 1 }
              end
            end
          end
        end
      end

      # Queue a pipeline run on the worker pool. A full queue is refused with
      # a visible busy reply — never executed inline on a transport thread.
      def dispatch_prompt(&blk)
        start_workers if @workers.empty? # embedded/test callers may skip #start
        @work_queue.push(blk, true)
      rescue ThreadError
        log 'Prompt queue saturated; refusing work (never executed inline).'
        begin
          @transport&.publish(RESPONSE_TOPIC, 'Error: dispatcher busy — retry')
        rescue StandardError
          nil
        end
      end

      def queue_capacity
        [max_concurrent_prompts * QUEUE_FACTOR, 8].max
      end

      # Tool RPCs get their own small allowance and never run on a transport
      # thread; at saturation the caller gets a visible busy error.
      def dispatch_tool_request(tool_id, payload)
        # Same dedupe as a prompt, for the opt-in direct tool RPC: an RPC that
        # arrives twice must not run a tool (and its side effects) twice.
        if (key = tool_ledger_key(tool_id, payload))
          unless @request_ledger.claim(key)
            log "[Ledger] duplicate tool request #{tool_id} ignored"
            begin
              @transport.publish("runes/tools/#{tool_id}/error",
                                 'Error: duplicate request ignored (already handled)')
            rescue StandardError
              nil
            end
            return
          end
        end

        take_slot = @tool_in_flight_mutex.synchronize do
          if @tool_in_flight >= max_tool_concurrent
            false
          else
            @tool_in_flight += 1
            true
          end
        end

        unless take_slot
          log "Tool worker pool saturated; refusing #{tool_id} request."
          @transport.publish("runes/tools/#{tool_id}/error", 'Error: dispatcher busy — retry')
          return
        end

        Thread.new do
          begin
            handle_tool_request(@transport, tool_id, payload)
          rescue => e
            log "Tool worker died: #{e.class}: #{e.message}"
          ensure
            @tool_in_flight_mutex.synchronize { @tool_in_flight -= 1 }
          end
        end
      end

      # A tool RPC payload may name its request; without one there is nothing
      # to dedupe on (see ledger_key).
      def tool_ledger_key(tool_id, payload)
        data = safe_parse_args(payload.is_a?(String) ? payload : JSON.generate(payload))
        request_id = data.is_a?(Hash) ? data['request_id'].to_s : ''
        return nil unless request_id.match?(REQUEST_ID_RE)

        Runes::RequestLedger.tool_key(tool_id, request_id)
      end

      def max_concurrent_prompts
        Integer(@settings.env('RUNES_MAX_CONCURRENT') || DEFAULT_MAX_CONCURRENT)
      rescue ArgumentError
        DEFAULT_MAX_CONCURRENT
      end

      def max_tool_concurrent
        Integer(@settings.env('RUNES_TOOL_CONCURRENT') || DEFAULT_MAX_TOOL_CONCURRENT)
      rescue ArgumentError
        DEFAULT_MAX_TOOL_CONCURRENT
      end

      # Deterministic shared id for non-envelope prompts (same prompt text ->
      # same id on every agent, so progress events correlate).
      def prompt_digest_id(prompt)
        "p#{Digest::SHA256.hexdigest(prompt.to_s)[0, 11]}"
      end

      # ---------- prompt pipeline ----------

      # Entry point for every prompt (broadcast-claimed, delegated or
      # conversational). Parses the envelope and routes by mode:
      #   build (default) -> plan/execute pipeline
      #   goal            -> rubber-duck PM conversation -> epic
      #   plan            -> requirement -> mission (todos file)
      # Entry point for every prompt (broadcast, delegated or A2A). Routes by
      # mode: build (default) -> plan/execute, goal -> epic chat, plan ->
      # mission, mission -> mission executor.
      #
      # `publisher` is the transport (kept positional so the pipeline stays
      # stubbable in tests).
      def handle_prompt(publisher, env, reply_topic: nil)
        env = parse_envelope(env) if env.is_a?(String)
        # S5-1 defense in depth: under signature enforcement, only an
        # envelope that came through Fabric#admitted_payload may execute.
        # A future inbound path that forgets the gate fails closed here
        # instead of silently running an unverified payload.
        if @require_signatures && env[:verified] != true
          log 'Refusing a prompt that did not pass the inbound signature gate.'
          publish_result(publisher, reply_topic, 'Error: unsigned or invalid envelope (path not admitted)')
          return
        end
        reply_topic ||= "runes/prompts/#{env[:request_id]}/response" if env[:from_envelope]

        # Inbound dedupe, before any work is queued: a redelivered QoS 1
        # PUBLISH or a publisher retry must not run the same request twice
        # (lib/runes/request_ledger.rb). Deliberately AFTER the signature gate
        # above: keying on an unverified request_id would let a publisher
        # suppress someone else's request.
        key = ledger_key(env)
        if key && !@request_ledger.claim(key)
          handle_duplicate_prompt(publisher, env, reply_topic, key)
          return
        end

        case env[:mode]
        when 'goal' then handle_goal_turn(publisher, env, reply_topic)
        when 'plan' then handle_plan(publisher, env, reply_topic)
        when 'mission' then handle_mission(publisher, env, reply_topic)
        else handle_build_prompt(publisher, env, reply_topic)
        end
      end

      # Only an envelope that names its request can be deduped. A plain
      # prompt's id is a digest of its text, so two deliberate repeats are
      # indistinguishable from one retry — and eating a user's second identical
      # prompt is worse than re-running it.
      def ledger_key(env)
        # An explicit key is the fabric saying "this envelope has a verified
        # identity even though it must not derive a reply topic from it" — the
        # delegated-task case, where an unsafe `from` suppresses the reply topic
        # but the request id is still the peer's identity for dedupe.
        return env[:dedupe_key] if env[:dedupe_key]

        return nil unless env[:from_envelope]

        request_id = env[:request_id].to_s
        return nil unless request_id.match?(REQUEST_ID_RE)

        Runes::RequestLedger.prompt_key(request_id)
      end

      # A duplicate is not an error the sender needs to fix; it is the same
      # request. Say so on the progress topic, and — if the first copy already
      # finished — answer the reply topic from the ledger instead of running
      # anything again. That is what makes a retry safe: it costs one message,
      # not one LLM call and one set of tool side effects.
      def handle_duplicate_prompt(publisher, env, reply_topic, key)
        request_id = env[:request_id]
        outcome = @request_ledger.outcome(key)
        log "[Ledger] duplicate request #{request_id} ignored " \
            "(#{outcome ? 'already complete' : 'still in flight'})"
        begin
          publisher.publish("runes/prompts/#{request_id}/progress",
                            JSON.generate(event: 'duplicate_ignored', request_id: request_id,
                                          at: Time.now.utc.iso8601,
                                          first_outcome: outcome))
          if outcome && reply_topic
            publisher.publish(reply_topic,
                              "Duplicate request ignored — already #{outcome}")
          end
        rescue StandardError => e
          log "Could not report a duplicate request: #{e.class}: #{e.message}"
        end
        nil
      end

      # Convenience for embeds/tests: parse a raw payload and run it.
      def handle_payload(payload, reply_topic: nil)
        handle_prompt(@transport, parse_envelope(payload), reply_topic: reply_topic)
      end

      # Parse a prompt payload into a normalized envelope Hash.
      # Accepts a raw string (build mode) or a JSON envelope:
      #   {"request_id","prompt","mode","session_id","control","epic_path"}
      # Unknown modes fall back to build. Non-JSON strings that merely
      # start with '{' stay plain build prompts.
      #
      # One canonical detection (D11): BOTH parsers must agree on what is
      # an envelope (`lstrip.start_with?('{')`), or the claim id and the
      # progress/reply topics can diverge on whitespace-prefixed payloads.
      def json_envelope?(payload)
        payload.is_a?(String) && payload.lstrip.start_with?('{')
      end

      def parse_envelope(payload)
        unless json_envelope?(payload)
          # Deterministic id for plain prompts (same text -> same id on
          # every agent) so progress events correlate with the claim.
          return {
            request_id: prompt_digest_id(payload.to_s), prompt: payload.to_s,
            mode: 'build', session_id: nil, control: nil, epic_path: nil,
            mission_path: nil, from_envelope: false
          }
        end

        env = safe_parse_args(payload)
        envelope_keys = %w[prompt mode control session_id epic_path mission_path request_id]
        unless env.keys.any? { |k| envelope_keys.include?(k) }
          # JSON but not an envelope — plain build prompt.
          return {
            request_id: prompt_digest_id(payload.to_s), prompt: payload.to_s,
            mode: 'build', session_id: nil, control: nil, epic_path: nil,
            mission_path: nil, from_envelope: false
          }
        end

        mode = env['mode'].to_s.strip.downcase
        mode = 'build' unless MODES.include?(mode)
        control = env['control'] == 'done' ? 'done' : nil
        raw_sid = env['session_id'].to_s
        session_id = raw_sid.match?(REQUEST_ID_RE) ? raw_sid : nil
        epic_path = env['epic_path'].to_s
        epic_path = nil unless valid_epic_path?(epic_path)
        # Mission paths may be 'latest', a bare filename inside
        # docs/missions/, or an (absolute) path there. They never become
        # topic fragments — the handler containment-checks them via
        # valid_mission_path? — so only control characters are rejected.
        mission_path = env['mission_path'].to_s
        mission_path = nil if !mission_path.empty? && mission_path.match?(/[[:cntrl:]]/)

        prompt = env['prompt'].to_s
        # Envelope ids are sanitized with a DETERMINISTIC fallback (D1):
        # a random fallback makes every agent claim a different topic and
        # execute (N agents, N executions) — a digest keeps the race
        # single-winner. Envelopes without an id digest the prompt.
        request_id = env['request_id'] ? sanitize_request_id(env['request_id']) : prompt_digest_id(prompt)

        {
          request_id: request_id,
          prompt: prompt,
          mode: mode,
          session_id: session_id,
          control: control,
          epic_path: epic_path,
          mission_path: mission_path,
          from_envelope: true
        }
      end

      # Epics referenced by clients must live in <root>/docs/epics — a
      # client cannot point the dispatcher at arbitrary files. Containment
      # requires the path separator (S-D1): a sibling directory whose name
      # extends the prefix (`docs/epics-evil/x.md`) must not pass.
      def valid_epic_path?(path)
        return false unless path.is_a?(String) && !path.empty?

        root = File.realpath(File.join(@settings.root, 'docs', 'epics'))
        return false unless File.file?(path)

        real = File.realpath(File.dirname(path))
        real == root || real.start_with?(root + File::SEPARATOR)
      rescue StandardError
        false
      end

      def load_latest_epic
        dir = File.join(@settings.root, 'docs', 'epics')
        return nil unless Dir.exist?(dir)

        Dir.glob(File.join(dir, '*.md')).sort.last
      end

      # Restored at boot so `/build latest` survives a daemon restart (D9).
      def load_latest_mission
        dir = File.join(@settings.root, 'docs', 'missions')
        return nil unless Dir.exist?(dir)

        Dir.glob(File.join(dir, '*.json')).sort.last
      end

      def handle_build_prompt(publisher, env, reply_topic)
        request_id = env[:request_id]
        prompt = env[:prompt]
        if prompt.bytesize > MAX_PROMPT_BYTES
          publisher.publish("runes/prompts/#{request_id}/progress",
                         JSON.generate(event: 'prompt_truncated', kept: MAX_PROMPT_BYTES))
        end
        prompt = truncate_prompt(prompt)
        progress_topic = "runes/prompts/#{request_id}/progress"
        publisher.publish(progress_topic, JSON.generate(event: 'prompt_received', request_id: request_id, prompt: prompt))

        log "Asking planner LLM (request=#{request_id})"
        res = plan_for(prompt)

        unless res[:ok]
          log "Planner error: #{res[:error]}"
          publish_result(publisher, reply_topic, "Planner error: #{res[:error]}")
          publisher.publish(progress_topic, JSON.generate(event: 'planner_error', error: res[:error]))
          record_prompt_log(publisher, request_id, prompt, status: 'planner_error', error: res[:error])
          return
        end

        steps = steps_from_result(res)
        if steps.empty?
          log 'Planner produced no parseable steps.'
          publish_result(publisher, reply_topic, 'Planner produced no steps.')
          publisher.publish(progress_topic, JSON.generate(event: 'plan_empty'))
          record_prompt_log(publisher, request_id, prompt, status: 'plan_empty')
          return
        end

        if steps.size > max_plan_steps
          log "Plan truncated from #{steps.size} to #{max_plan_steps} steps."
          steps = steps.take(max_plan_steps)
          publisher.publish(progress_topic, JSON.generate(event: 'plan_truncated', kept: max_plan_steps))
        end

        publisher.publish(progress_topic, JSON.generate(event: 'plan_ready', request_id: request_id, steps: steps.size))
        log "Executing #{steps.size} step(s) (request=#{request_id})"

        results = steps.map.with_index do |step, i|
          publisher.publish(progress_topic, JSON.generate(event: 'step_start', step: i + 1, tool: step[:tool]))
          outcome = execute_step(step, i + 1)
          publisher.publish(progress_topic, JSON.generate(event: 'step_end', step: i + 1, tool: step[:tool], outcome: outcome.to_s[0, 500]))
          { step: i + 1, tool: step[:tool], outcome: outcome }
        end

        summary = summarize(prompt, results)
        publish_result(publisher, reply_topic, summary)
        publisher.publish(progress_topic, JSON.generate(event: 'prompt_complete', request_id: request_id))
        record_prompt_log(publisher, request_id, prompt, status: 'complete', summary: summary[0, 500])
        log 'Response published.'
      end

      # ---------- goal mode (epic) ----------

      EPIC_RENDER_INSTRUCTION = <<~PROMPT.freeze
        Based on our whole conversation, render the final epic document
        now. Markdown, exactly these sections, no preamble:
          # Epic: <short title>
          ## Problem
          ## Target users
          ## Goals
          ## Non-goals
          ## Success criteria
          ## Constraints & assumptions
          ## Open questions
        Fill only from what was discussed; mark unknowns as TBD.
      PROMPT

      def handle_goal_turn(publisher, env, reply_topic)
        request_id = env[:request_id]
        progress_topic = "runes/prompts/#{request_id}/progress"

        if env[:control] == 'done'
          # A client-supplied session id is required to finalize a shared
          # session; a client that never opened one gets the daemon's
          # only open goal session (one-shot CLI flows, D8) — never a
          # random sid that can never match.
          sid = env[:session_id] || sole_goal_session_id
          if sid.nil?
            publish_result(publisher, reply_topic, 'No goal session to finalize — start with /goal <text>.')
            return
          end
          finalize_epic(publisher, env, reply_topic, sid)
          return
        end

        # A client that did not supply a session id (e.g. one-shot CLI
        # goal turns) gets an ephemeral server-side session — never a
        # shared nil key that every client would join.
        sid = env[:session_id] || "s-#{SecureRandom.hex(3)}"

        prompt = truncate_prompt(env[:prompt].to_s)
        if prompt.strip.empty?
          publish_result(publisher, reply_topic, 'Describe your need after /goal (e.g. /goal a CLI pomodoro).')
          return
        end

        session = open_session(sid)
        session[:mutex].synchronize do
          session[:messages] << { 'role' => 'user', 'content' => prompt }

          res = goal_chat(session[:messages])

          unless res[:ok]
            session[:messages].pop # do not keep the turn the planner never saw answered
            publisher.publish(progress_topic, JSON.generate(event: 'planner_error', error: res[:error]))
            publish_result(publisher, reply_topic, "Planner error: #{res[:error]}")
            record_prompt_log(publisher, request_id, prompt, status: 'goal_error', error: res[:error])
            next
          end

          assistant = res[:content].to_s
          session[:messages] << { 'role' => 'assistant', 'content' => assistant }
          trim_session_history(session)
          session[:last_turn_at] = Time.now
          publisher.publish(progress_topic, JSON.generate(event: 'conversation', session_id: sid, text: assistant[0, 2000]))
          publish_result(publisher, reply_topic, assistant)
          record_prompt_log(publisher, request_id, prompt, status: 'goal_turn', summary: assistant[0, 500])
        end
      end

      def finalize_epic(publisher, env, reply_topic, sid)
        request_id = env[:request_id]
        progress_topic = "runes/prompts/#{request_id}/progress"
        session = @sessions_mutex.synchronize { @sessions[sid] }

        if session.nil? || Array(session[:messages]).empty?
          publish_result(publisher, reply_topic, 'No goal session to finalize — start with /goal <text>.')
          return
        end

        session[:mutex].synchronize do
          session[:messages] << { 'role' => 'user', 'content' => EPIC_RENDER_INSTRUCTION }
          res = goal_chat(session[:messages])

          unless res[:ok]
            session[:messages].pop # drop the instruction so /done can retry cleanly
            publisher.publish(progress_topic, JSON.generate(event: 'planner_error', error: res[:error]))
            publish_result(publisher, reply_topic, "Planner error: #{res[:error]}")
            record_prompt_log(publisher, request_id, 'finalize epic', status: 'goal_error', error: res[:error])
            next
          end

          epic_md = res[:content].to_s
          unless valid_epic_markdown?(epic_md)
            session[:messages].pop
            publisher.publish(progress_topic, JSON.generate(event: 'epic_invalid', raw: epic_md[0, 400]))
            publish_result(publisher, reply_topic, 'Epic render was not usable (missing required sections) — session kept open; /done to retry.')
            return
          end

          title_hint = session[:messages].find { |m| m['role'] == 'user' && m['content'] != EPIC_RENDER_INSTRUCTION }&.dig('content').to_s
          path = write_artifact('epics', epic_md, title_hint)
          unless path
            session[:messages].pop
            publisher.publish(progress_topic, JSON.generate(event: 'epic_write_failed'))
            publish_result(publisher, reply_topic, 'Epic could not be written to disk — session kept open; /done to retry.')
            return
          end

          @latest_epic = path
          close_session(sid)

          publisher.publish(progress_topic, JSON.generate(event: 'epic_written', session_id: sid, path: path))
          publish_result(publisher, reply_topic, "Epic written to #{path}\n\n#{epic_md[0, 800]}")
          record_prompt_log(publisher, request_id, title_hint[0, 200], status: 'epic_written', summary: path)
          log "Epic written: #{path}"
        end
      end

      def valid_epic_markdown?(md)
        md = md.to_s
        md.include?('# Epic') && md.include?('## ') && md.length >= 60
      end

      # ---------- plan mode (mission) ----------

      def handle_plan(publisher, env, reply_topic)
        request_id = env[:request_id]
        progress_topic = "runes/prompts/#{request_id}/progress"
        text = truncate_prompt(env[:prompt].to_s).strip
        epic_path = env[:epic_path]
        epic_path = nil unless epic_path && valid_epic_path?(epic_path)
        epic_path ||= @latest_epic

        source, source_label =
          if text.empty?
            if epic_path && File.file?(epic_path)
              [truncate_prompt(File.read(epic_path)), "epic #{File.basename(epic_path)}"]
            else
              msg = 'No epic available yet — describe your need with /goal first (or /plan <text>).'
              publisher.publish(progress_topic, JSON.generate(event: 'conversation', text: msg))
              publish_result(publisher, reply_topic, msg)
              return
            end
          else
            [text, 'brief']
          end

        publisher.publish(progress_topic, JSON.generate(event: 'mission_planning', source: source_label))
        mission = request_mission(publisher, progress_topic, source, source_label, reply_topic: reply_topic)
        return if mission.nil?

        sidecar = {
          'mission_title' => mission['mission_title'],
          'source' => source_label,
          'source_path' => (source_label.start_with?('epic') ? epic_path : nil),
          'todos' => mission['todos']
        }
        md = render_mission_markdown(mission, source_label)
        path = write_artifact('missions', md, mission['mission_title'], sidecar: sidecar)
        unless path
          publisher.publish(progress_topic, JSON.generate(event: 'mission_write_failed'))
          publish_result(publisher, reply_topic, 'Mission could not be written to disk.')
          return
        end
        @latest_mission = path

        publisher.publish(progress_topic, JSON.generate(event: 'mission_written', path: path, todos: mission['todos'].size))
        publish_result(publisher, reply_topic, "Mission written to #{path} (#{mission['todos'].size} todos)\n\n#{md[0, 1000]}")
        record_prompt_log(publisher, request_id, source[0, 500], status: 'mission_written', summary: path)
        log "Mission written: #{path}"
      end

      def request_mission(publisher, progress_topic, source, source_label, reply_topic:, messages: nil, attempt: 0)
        messages ||= [{ 'role' => 'user', 'content' => "Requirement (#{source_label}):\n\n#{source}\n\nProduce the mission JSON." }]
        # Mission rendering is a format conversion of an already-refined
        # requirement (goal mode did the thinking) — reasoning 'low'
        # keeps it fast; the default variation stays 'high' elsewhere.
        res = @llm.chat(messages, system: mission_system_prompt, json: true, variation: 'low')
        unless res[:ok]
          publisher.publish(progress_topic, JSON.generate(event: 'planner_error', error: res[:error]))
          publish_result(publisher, reply_topic, "Planner error: #{res[:error]}")
          return nil
        end

        parsed = extract_json_object(res[:content].to_s)
        todos = parsed.is_a?(Hash) ? parsed['todos'] : nil
        valid = todos.is_a?(Array) && !todos.empty? &&
                todos.all? { |t| t.is_a?(Hash) && !t['title'].to_s.strip.empty? }

        if valid
          todos.each_with_index do |t, i|
            t['id'] ||= i + 1
            t['done'] = false
          end
          parsed['mission_title'] = parsed['mission_title'].to_s.strip.empty? ? 'mission' : parsed['mission_title'].to_s
          parsed
        elsif attempt >= 1
          publisher.publish(progress_topic, JSON.generate(event: 'mission_invalid', raw: res[:content].to_s[0, 400]))
          publish_result(publisher, reply_topic, 'Mission planner kept producing invalid JSON — no mission file written.')
          nil
        else
          messages << { 'role' => 'assistant', 'content' => res[:content].to_s[0, 4000] }
          messages << { 'role' => 'user', 'content' => MISSION_RETRY_INSTRUCTION }
          request_mission(publisher, progress_topic, source, source_label, reply_topic: reply_topic,
                          messages: messages, attempt: attempt + 1)
        end
      end

      MISSION_RETRY_INSTRUCTION = <<~PROMPT.freeze
        That was not valid mission JSON. Respond again with STRICT JSON
        only: {"mission_title": "...", "todos": [{"id": 1, "title":
        "...", "detail": "...", "acceptance": "..."}]} — no markdown, no
        fences, no prose.
      PROMPT

      # Shared, string-aware extractor (E4-4/B4-4). Kept as a shim so callers
      # that reached into the private method keep working; the brace-blind
      # local scanner that rejected valid missions is gone.
      def extract_json_object(text)
        Runes::Core::JsonScan.extract_object(text)
      end

      def render_mission_markdown(mission, source_label)
        lines = ["# Mission: #{mission['mission_title']}", '', "_Source: #{source_label}_", '', '## Todos', '']
        mission['todos'].each do |t|
          lines << "- [ ] #{t['id']}. #{t['title']}"
          lines << "    - #{t['detail']}" if t['detail'].to_s.strip != ''
          lines << "    - acceptance: #{t['acceptance']}" if t['acceptance'].to_s.strip != ''
        end
        lines.join("\n") + "\n"
      end

      # ---------- mission mode (/build <mission>) ----------

      # Sequential todo executor: loads a mission's JSON sidecar, and for
      # each pending todo (1) asks the planner for build steps and runs
      # them through the guarded tool pipeline, (2) asks a QA-verifier
      # whether the acceptance criteria are met, (3) ticks the sidecar +
      # re-renders the markdown. Already-done todos are skipped, so a
      # crashed run resumes with /build again. Fails loud and stops at
      # the first failed todo unless RUNES_MISSION_CONTINUE=1.
      def handle_mission(publisher, env, reply_topic)
        request_id = env[:request_id]
        progress_topic = "runes/prompts/#{request_id}/progress"

        path = env[:mission_path].to_s.strip
        path = env[:prompt].to_s.strip if path.empty?

        resolved = resolve_mission_path(path)
        unless resolved
          msg = path.to_s.strip.empty? ? 'No mission known yet — run /plan first (or /build <mission-file>).'
                                       : "Mission not found in docs/missions/: #{path[0, 80]}"
          publisher.publish(progress_topic, JSON.generate(event: 'conversation', text: msg))
          publish_result(publisher, reply_topic, msg)
          return
        end

        sidecar, json_path = load_mission(resolved)
        unless sidecar
          msg = "Mission file has no usable JSON sidecar: #{resolved[0, 80]}"
          publisher.publish(progress_topic, JSON.generate(event: 'conversation', text: msg))
          publish_result(publisher, reply_topic, msg)
          return
        end

        md_path = json_path.sub(/\.json\z/, '.md')
        pending = sidecar['todos'].reject { |t| t['done'] }

        if pending.empty?
          publisher.publish(progress_topic, JSON.generate(event: 'mission_complete', path: md_path, already: true))
          publish_result(publisher, reply_topic, "Mission '#{sidecar['mission_title']}' is already complete (#{sidecar['todos'].size} todos).")
          return
        end

        publisher.publish(progress_topic, JSON.generate(event: 'mission_started',
                                                     path: md_path, total: sidecar['todos'].size, pending: pending.size))
        log "Mission run: #{sidecar['mission_title']} (#{pending.size}/#{sidecar['todos'].size} pending)"

        pending.each do |todo|
          publisher.publish(progress_topic, JSON.generate(event: 'mission_step_start', todo_id: todo['id'], title: todo['title']))
          outcome = execute_mission_step(publisher, progress_topic, sidecar, todo)
          verdict = verify_mission_step(todo, outcome[:evidence] || outcome[:summary])
          todo['result'] = "#{verdict['verdict']}: #{verdict['reason']} | #{outcome[:summary][0, 300]}"

          if verdict['verdict'] == 'pass'
            todo['done'] = true
            save_mission(sidecar, json_path, md_path)
            publisher.publish(progress_topic, JSON.generate(event: 'mission_step_done', todo_id: todo['id'], verdict: 'pass'))
            record_prompt_log(publisher, request_id, "todo #{todo['id']}: #{todo['title']}", status: 'mission_step', summary: verdict['reason'][0, 300])
          else
            save_mission(sidecar, json_path, md_path)
            publisher.publish(progress_topic, JSON.generate(event: 'mission_step_failed', todo_id: todo['id'],
                                                         reason: verdict['reason'][0, 300]))
            break unless mission_continue_on_fail?
            record_prompt_log(publisher, request_id, "todo #{todo['id']}: #{todo['title']}", status: 'mission_step', summary: verdict['reason'][0, 300])
          end
        end

        if sidecar['todos'].all? { |t| t['done'] }
          publisher.publish(progress_topic, JSON.generate(event: 'mission_complete', path: md_path))
          publish_result(publisher, reply_topic, "Mission complete: #{md_path} (#{sidecar['todos'].size} todos done).")
          record_prompt_log(publisher, request_id, sidecar['mission_title'].to_s, status: 'mission_complete', summary: md_path)
        else
          publisher.publish(progress_topic, JSON.generate(event: 'mission_failed',
                                                       path: md_path,
                                                       remaining: sidecar['todos'].count { |t| !t['done'] }))
          publish_result(publisher, reply_topic, "Mission stopped: #{md_path} — re-run /build to resume remaining todos.")
          record_prompt_log(publisher, request_id, sidecar['mission_title'].to_s, status: 'mission_failed', summary: md_path)
        end
      end

      # 'latest' (or empty) -> newest known mission; relative names resolve
      # inside docs/missions/; everything is containment-checked.
      def resolve_mission_path(path)
        path = path.to_s.strip
        return @latest_mission if path.empty? || path == 'latest'

        candidate = path
        unless candidate.start_with?('/')
          candidate = File.join(@settings.root, 'docs', 'missions', candidate)
        end
        valid_mission_path?(candidate) ? candidate : nil
      end

      # Containment requires the path separator (S-D1) — same rule as
      # valid_epic_path?/safe_path.
      def valid_mission_path?(path)
        return false unless path.is_a?(String) && !path.empty?

        root = File.realpath(File.join(@settings.root, 'docs', 'missions'))
        return false unless File.file?(path)

        real = File.realpath(File.dirname(path))
        real == root || real.start_with?(root + File::SEPARATOR)
      rescue StandardError
        false
      end

      # Returns [sidecar_hash, json_path]; accepts .md or .json input.
      def load_mission(path)
        json_path = path.end_with?('.json') ? path : path.sub(/\.md\z/, '.json')
        return [nil, nil] unless File.file?(json_path)

        sidecar = JSON.parse(File.read(json_path))
        return [nil, nil] unless sidecar.is_a?(Hash) && sidecar['todos'].is_a?(Array)

        [sidecar, json_path]
      rescue JSON::ParserError, IOError
        [nil, nil]
      end

      def save_mission(sidecar, json_path, md_path)
        # Atomic writes (D7): a crash mid-write must never truncate the
        # sidecar and permanently break crash-resume.
        atomic_write(json_path, JSON.generate(sidecar))
        atomic_write(md_path, render_mission_sidecar_markdown(sidecar))
        true
      rescue => e
        log "Mission save failed: #{e.message}"
        false
      end

      # tmp file + rename: readers only ever see a complete file.
      def atomic_write(path, content)
        tmp = "#{path}.tmp-#{SecureRandom.hex(4)}"
        File.write(tmp, content)
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if tmp && File.file?(tmp)
      end

      def render_mission_sidecar_markdown(sidecar)
        lines = ["# Mission: #{sidecar['mission_title']}", '']
        src = sidecar['source'].to_s.strip
        lines << "_Source: #{src}_" unless src.empty?
        lines << '' << '## Todos' << ''
        sidecar['todos'].each do |t|
          box = t['done'] ? 'x' : ' '
          lines << "- [#{box}] #{t['id']}. #{t['title']}"
          lines << "    - #{t['detail']}" if t['detail'].to_s.strip != ''
          lines << "    - acceptance: #{t['acceptance']}" if t['acceptance'].to_s.strip != ''
          lines << "    - result: #{t['result']}" if t['result'].to_s.strip != ''
        end
        lines.join("\n") + "\n"
      end

      def mission_continue_on_fail?
        %w[1 true yes on].include?(@settings.env('RUNES_MISSION_CONTINUE').to_s.downcase)
      end

      # Evidence budget handed to the QA verifier (E4-7). This replaced the
      # 200-char `summarize` line, which starved the verifier of exactly the
      # read-back output it is asked to judge (B4-6).
      MISSION_EVIDENCE_BYTES = 8 * 1024

      # Runs the planner for ONE todo and executes its steps through the
      # guarded tool pipeline. Returns { ok:, summary:, evidence: }.
      def execute_mission_step(publisher, progress_topic, sidecar, todo)
        step_prompt = mission_step_prompt(sidecar, todo)
        # Same planner path as build mode (E4-8): missions used to bypass
        # function calling and the manifest tool schemas entirely (B4-5).
        res = plan_for(step_prompt)
        unless res[:ok]
          publisher.publish(progress_topic, JSON.generate(event: 'planner_error', error: res[:error]))
          return { ok: false, summary: "planner error: #{res[:error]}",
                   evidence: "planner error: #{res[:error]}" }
        end

        steps = steps_from_result(res)
        if steps.empty?
          return { ok: true, summary: 'planner produced no steps for this todo',
                   evidence: '(planner produced no steps for this todo)' }
        end

        steps = steps.take(max_plan_steps)
        outcomes = steps.map.with_index do |step, i|
          publisher.publish(progress_topic, JSON.generate(event: 'mission_step_tool',
                                                       todo_id: todo['id'], step: i + 1, tool: step[:tool]))
          { step: i + 1, tool: step[:tool], outcome: execute_step(step, i + 1) }
        end
        {
          ok: true,
          summary: summarize("todo #{todo['id']}: #{todo['title']}", outcomes),
          evidence: mission_evidence(outcomes)
        }
      rescue => e
        { ok: false, summary: "#{e.class}: #{e.message}", evidence: "#{e.class}: #{e.message}" }
      end

      # Bounded, explicitly-marked raw output for the verifier (E4-7).
      def mission_evidence(outcomes)
        buf = String.new
        outcomes.each do |o|
          chunk = "--- step #{o[:step]} (#{o[:tool]}) ---\n#{o[:outcome]}\n"
          remaining = MISSION_EVIDENCE_BYTES - buf.bytesize
          if remaining <= 0
            buf << "\n[evidence truncated at #{MISSION_EVIDENCE_BYTES} bytes]\n"
            break
          end
          buf << (chunk.bytesize > remaining ? chunk.byteslice(0, remaining).to_s.scrub : chunk)
        end
        buf
      end

      def mission_step_prompt(sidecar, todo)
        <<~PROMPT
          You are executing ONE todo of the mission "#{sidecar['mission_title']}".

          Todo #{todo['id']}: #{todo['title']}
          Detail: #{todo['detail']}
          Acceptance criteria: #{todo['acceptance']}

          Implement exactly this todo — do not implement other todos. Use
          workspace-relative paths only.

          IMPORTANT — evidence: a strict QA verifier judges the acceptance
          criteria from your execution output alone. Always finish with a
          verification step that PRODUCES EVIDENCE, e.g. read_file the
          file you wrote, or run_command a check that prints the result
          (short commands only — they are killed after 10 seconds).
        PROMPT
      end

      # Strict QA gate: pass only on stated evidence; anything else
      # (including verifier hiccups) is fail-closed.
      def verify_mission_step(todo, evidence)
        res = @llm.chat(
          [{ 'role' => 'user', 'content' => verify_prompt(todo, evidence) }],
          system: Runes::Core::LLMClient::MISSION_VERIFY_SYSTEM_PROMPT, json: true, variation: 'low'
        )
        return { 'verdict' => 'fail', 'reason' => "verifier unavailable: #{res[:error]}" } unless res[:ok]

        # S-D2: the verdict must be the WHOLE reply, parsed strictly.
        # The old first-balanced-brace scan let workspace content (which
        # flows into the outcome text) inject a fake pass verdict.
        parsed = strict_json_reply(res[:content].to_s)
        return { 'verdict' => 'fail', 'reason' => 'verifier reply was not strict JSON' } if parsed.nil?

        verdict = parsed['verdict'].to_s.strip.downcase
        reason = parsed['reason'].to_s.strip
        case verdict
        when 'pass' then { 'verdict' => 'pass', 'reason' => reason }
        else { 'verdict' => 'fail', 'reason' => reason.empty? ? 'verifier did not confirm pass' : reason }
        end
      end

      # The reply must parse as JSON in full (a single fenced code block
      # is tolerated); ambiguity is a fail (S-D2).
      # Never hand the verifier an empty or clipped-to-nothing payload:
      # distinguish "no evidence" from "short evidence" (E4-7).
      def verify_prompt(todo, evidence)
        text = evidence.to_s
        budget = MISSION_EVIDENCE_BYTES
        shown =
          if text.strip.empty?
            '(no execution output was produced)'
          elsif text.bytesize > budget
            text.byteslice(0, budget).to_s.scrub + "\n[evidence truncated at #{budget} bytes]"
          else
            text
          end
        "Todo #{todo['id']}: #{todo['title']}\n" \
          "Acceptance criteria: #{todo['acceptance']}\n\n" \
          "Execution outcome:\n#{shown}\n\nHas the acceptance criteria been met?"
      end

      def strict_json_reply(text)
        stripped = text.strip
        if stripped.start_with?('```')
          stripped = stripped.sub(/\A```[a-zA-Z]*\n?/, '').sub(/```\s*\z/, '').strip
        end
        JSON.parse(stripped)
      rescue JSON::ParserError
        nil
      end

      # ---------- goal/plan LLM helpers ----------

      def goal_chat(messages)
        @llm.chat(messages, system: goal_system_prompt)
      end

      def goal_system_prompt
        Runes::Core::LLMClient::GOAL_SYSTEM_PROMPT
      end

      def mission_system_prompt
        Runes::Core::LLMClient::MISSION_SYSTEM_PROMPT
      end

      # ---------- artifacts (host-side, never LLM-controlled paths) ----------

      def write_artifact(kind, content, title_hint, sidecar: nil)
        dir = File.join(@settings.root, 'docs', kind)
        FileUtils.mkdir_p(dir)
        # Unique suffix kills same-second filename collisions (D7).
        base = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}-#{slugify(title_hint)}"
        path = File.join(dir, "#{base}.md")
        atomic_write(path, content)
        atomic_write(File.join(dir, "#{base}.json"), JSON.generate(sidecar)) if sidecar
        path
      rescue => e
        log "Artifact write failed: #{e.message}"
        nil
      end

      def slugify(text)
        s = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')[0, 40].gsub(/-+$/, '')
        s.to_s.empty? ? 'untitled' : s
      end

      def parse_prompt_payload(payload)
        # Same envelope detection as parse_envelope (D11).
        return [prompt_digest_id(payload.to_s), payload.to_s, false] unless json_envelope?(payload)
        env = safe_parse_args(payload)
        return [prompt_digest_id(payload.to_s), payload.to_s, false] unless env['prompt']

        if env['request_id']
          [env['request_id'].to_s, env['prompt'], true]
        else
          # Deterministic (D1): a per-agent random id makes every
          # dispatcher claim a different topic and execute.
          [prompt_digest_id(env['prompt']), env['prompt'], true]
        end
      end

      # Request ids become MQTT topic fragments; constrain them to a
      # safe charset and length. The fallback is a DETERMINISTIC digest
      # of the raw id (D1): every dispatcher must derive the SAME id for
      # the claim race to coordinate — a random fallback made every
      # agent win its own one-agent race and execute.
      def sanitize_request_id(raw)
        id = raw.to_s
        return id if id.match?(REQUEST_ID_RE)
        "r#{Digest::SHA256.hexdigest(id)[0, 11]}"
      end

      # Fan a result out to the global response topic and, when present,
      # the correlated reply topic.
      def publish_result(publisher, reply_topic, summary)
        publisher.publish(RESPONSE_TOPIC, summary)
        publisher.publish(reply_topic, summary) if reply_topic
      end

      def max_plan_steps
        Integer(@settings.env('RUNES_MAX_STEPS') || MAX_PLAN_STEPS)
      rescue ArgumentError
        MAX_PLAN_STEPS
      end

      # ---------- planner modes ----------

      # Function calling is the DEFAULT planner path: the planner
      # receives OpenAI-style tool schemas and replies with structured
      # tool_calls (live-validated end-to-end with a multi-tool GLM run —
      # demo/tool_calls_live.rb). Opt OUT with RUNES_USE_TOOLS=0 to get
      # the legacy free-form JSON plan format.
      def use_tool_calling?
        val = @settings.env('RUNES_USE_TOOLS').to_s.downcase
        !%w[0 false no off].include?(val)
      end

      def tool_schemas
        extra = @registry.cards.values.filter_map do |card|
          next nil unless card.is_a?(Hash) && card['name']
          # tools/ ships manifests for the builtins as well; their schemas
          # are already in builtin_schemas, and a duplicate tool name makes
          # the whole planner request invalid (DeepSeek HTTP 400).
          next nil if BUILTIN_TOOLS.include?(card['name'])

          {
            type: 'function',
            function: {
              name: card['name'],
              description: card['description'].to_s,
              parameters: (card['parameters'] || { type: 'object', properties: {} })
            }
          }
        end
        Runes::Core::LLMClient.builtin_schemas(extra: extra)
      end

      # One planner entry point for build mode AND mission steps (E4-8):
      # missions used to call @llm.call directly, silently bypassing the
      # function-calling default and the manifest tool schemas (B4-5).
      def plan_for(prompt)
        if use_tool_calling?
          @llm.call(prompt, tools: tool_schemas)
        else
          @llm.call(prompt)
        end
      end

      def steps_from_result(res)
        if res[:mode] == :tool_calls
          Array(res[:tool_calls]).map { |tc| { tool: tc[:tool], args: tc[:args] || {} } }
        else
          @plan_parser.parse(res[:content])
        end
      end

      def summarize(prompt, results)
        lines = ["Plan for: #{prompt}"]
        results.each do |r|
          body = r[:outcome].to_s.strip.gsub(/\s+/, ' ')
          lines << format('  %d. %-12s -> %s', r[:step], r[:tool], body[0, 200])
        end
        lines.join("\n")
      end

      # ---------- tool execution ----------

      def handle_tool_request(publisher, tool_id, payload)
        args = safe_parse_args(payload)

        # S4-1/E4-6: this topic is an execution API. Require the shared
        # secret before any tool id (builtin or manifest) is considered.
        # S5-4: the request must also be fresh (ts/nonce MAC) and not a
        # replay.
        unless rpc_authorized?(args, tool_id)
          log "[RPC] rejected unauthenticated request for #{tool_id}"
          publisher.publish("runes/tools/#{tool_id}/error",
                         'Error: unauthorized (tool RPC requires the shared secret)')
          return
        end
        args = args.reject { |k, _| Runes::Security::RPCAuth::AUTH_FIELDS.include?(k.to_s) }

        if BUILTIN_TOOLS.include?(tool_id)
          # Builtins are host-trusted: the Guard gates their dangerous
          # capabilities (fs_read/fs_write/exec) inside execute_builtin.
          # Requiring an `mqtt_publish` grant here made the whole builtin
          # RPC path dead code (D6) — builtins publish only on their own
          # response topic.
          #
          # S5-7: execute_builtin must never kill the tool worker without
          # a reply, so a raise here becomes an error result.
          result = begin
            execute_builtin(tool_id, args)
          rescue StandardError => e
            "Error: #{e.class}: #{e.message}"
          end
          publisher.publish("runes/tools/#{tool_id}/response", result)
          return
        end

        unless @guard.allowed?(tool_id, :mqtt_publish, "runes/tools/#{tool_id}/response")
          log "[Guard] blocked #{tool_id}"
          # Never publish to the topic the policy just denied; report on
          # the tool's error channel instead.
          publisher.publish("runes/tools/#{tool_id}/error", 'Error: capability denied')
          return
        end

        result = begin
          execute_manifest_tool(tool_id, args)
        rescue StandardError => e
          "Error: #{e.class}: #{e.message}"
        end
        publisher.publish("runes/tools/#{tool_id}/response", result)
      end

      # Constant-time shared-secret check so the secret cannot be probed by
      # timing, plus a freshness check (timestamp + nonce MAC) so a
      # captured request cannot be replayed. Returns false when RPC is
      # disabled or no/incorrect/stale token was supplied.
      def rpc_authorized?(args, tool_id = nil)
        return false unless tool_rpc_enabled?

        supplied = args['token'].to_s.b
        expected = rpc_secret.to_s.b
        return false if supplied.empty? || expected.empty?
        return false unless Runes::Security::RPCAuth.secure_compare(supplied, expected)

        Runes::Security::RPCAuth.fresh?(
          rpc_secret,
          tool_id.to_s,
          args,
          cache: (@rpc_nonces ||= Runes::Security::RPCAuth::NonceCache.new)
        )
      end

      def execute_step(step, index)
        tool = step[:tool].to_s
        args = step[:args] || {}
        log "Step #{index}: #{tool} (#{args.keys.join(', ')})"

        return execute_builtin(tool, args) if BUILTIN_TOOLS.include?(tool)
        return execute_manifest_tool(tool, args) if @registry.cards.key?(tool)

        "Error: unknown tool #{tool}"
      rescue => e
        "Error: #{e.class}: #{e.message}"
      end

      # Non-builtin tools declared in tools/<name>/ are executed inside
      # the WASM sandbox (real ruby.wasm or mock backend). The tool's
      # run.rb reads its JSON args from STDIN; inside the sandbox we
      # rewrite that read to a workspace-hosted args file.
      def execute_manifest_tool(tool_id, args)
        # S-W3: manifest tools were executed unconditionally — declared
        # capabilities were merged into policy but never enforced. The
        # registry grants `execute` per registered tool; a policy file
        # can deny it.
        unless @guard.allowed?(tool_id, :execute, tool_id)
          log "[Guard] denied execute for manifest tool #{tool_id}"
          return "Error: capability denied (execute #{tool_id})"
        end

        # Ask the registry where manifests actually live: assuming
        # `<root>/tools` broke the WASM tool path whenever the project root
        # was relocated (custom tools_dir / RUNES_ROOT — B4-13 fallout).
        tools_dir = @registry.respond_to?(:tools_dir) ? @registry.tools_dir : File.join(@settings.root, 'tools')
        src_path = File.join(tools_dir, tool_id, 'run.rb')
        return "Error: no implementation for #{tool_id}" unless File.file?(src_path)

        args_file = ".runes-args-#{SecureRandom.uuid[0, 8]}.json"
        args_abs  = File.join(@workspace, args_file)
        File.write(args_abs, JSON.generate(args))

        # Tool contract (see tools/echo/run.rb): the tool reads its JSON
        # args with `STDIN.read`. Inside the sandbox the program itself
        # arrives on stdin, so we rewrite that read to a workspace-hosted
        # args file (tolerant of surrounding whitespace).
        src = File.read(src_path).gsub(/STDIN\s*\.\s*read/, "File.read('/workspace/#{args_file}')")
        result = nil
        @vm_manager.with_vm do |vm|
          result = vm.run(src)
        end
        # Mock results are marked explicitly so demos never masquerade
        # as real executions (W6).
        if result[:mock]
          result[:ok] ? "[mock backend] WASM(#{tool_id}): #{result[:stdout]}" : "[mock backend] WASM(#{tool_id}) error: #{result[:error]}"
        else
          suffix = result[:truncated] ? ' (output truncated)' : ''
          result[:ok] ? "WASM(#{tool_id}): #{result[:stdout]}#{suffix}" : "WASM(#{tool_id}) error: #{result[:error]}"
        end
      rescue => e
        "Error: #{e.class}: #{e.message}"
      ensure
        File.delete(args_abs) if args_abs && File.file?(args_abs)
      end

      def execute_builtin(tool_id, args)
        case tool_id
        when 'write_file'
          return 'Error: invalid args (missing path)' if args['path'].nil? || args['path'].to_s.empty?
          path = safe_path(args['path'])
          return 'Error: invalid args' if path.nil?
          # "" is a legitimate payload (touch/truncate); only a MISSING key
          # is invalid (B4-8).
          return 'Error: missing content' unless args.key?('content')

          content = args['content'].to_s
          # S4-4: the capability decision and the write target must be the
          # same path — judge the workspace-relative path actually written,
          # not the raw (unresolved) planner string.
          resource = relative_to_workspace(path)
          return 'Error: capability denied (fs_write)' unless @guard.allowed?('write_file', :fs_write, resource)
          return "Error: content exceeds write cap (#{write_cap}B)" if content.bytesize > write_cap

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          "Wrote #{resource} (#{content.bytesize}B)"
        when 'read_file'
          path = safe_path(args['path'])
          return 'Error: invalid args' if path.nil?
          resource = relative_to_workspace(path)
          return 'Error: capability denied (fs_read)' unless @guard.allowed?('read_file', :fs_read, resource)
          return 'Error: not found' unless File.file?(path)
          return "Error: file exceeds read cap (#{read_cap}B)" if File.size(path) > read_cap

          File.read(path)
        when 'run_command'
          cmd = args['cmd'].to_s
          return 'Error: invalid args' if cmd.empty?
          return 'Error: capability denied (exec)' unless @guard.allowed?('run_command', :exec, cmd)

          run_in_workspace(cmd)
        else
          "Error: unsupported tool #{tool_id}"
        end
      end

      def write_cap
        Integer(@settings.env('RUNES_WRITE_CAP') || DEFAULT_WRITE_CAP)
      rescue ArgumentError
        DEFAULT_WRITE_CAP
      end

      def read_cap
        Integer(@settings.env('RUNES_READ_CAP') || DEFAULT_READ_CAP)
      rescue ArgumentError
        DEFAULT_READ_CAP
      end

      # ---------- path / command safety ----------

      def safe_path(raw)
        return nil if raw.nil? || raw.to_s.empty?
        # S5-7: File.expand_path raises ArgumentError on a NUL byte, which
        # used to kill the tool worker with no reply. Reject it here.
        return nil if raw.to_s.include?("\0")
        return nil if raw.to_s.start_with?('/')

        expanded = File.expand_path(raw.to_s, @workspace)
        root_lexical = File.expand_path(@workspace)
        return nil unless expanded.start_with?(root_lexical + File::SEPARATOR)

        # Lexical expansion is not enough: a symlink inside the workspace
        # can point outside. Resolve the deepest existing ancestor with
        # realpath and re-check containment against the workspace's own
        # realpath (which may itself differ lexically, e.g. /var vs
        # /private/var on macOS).
        root_real = File.realpath(root_lexical)
        constrained = resolve_realpath_within(expanded, root_real)
        return nil unless constrained&.start_with?(root_real + File::SEPARATOR) || constrained == root_real

        expanded
      end

      def resolve_realpath_within(path, root)
        candidate = path
        remainder = ''
        until File.exist?(candidate) || File.symlink?(candidate)
          parent = File.dirname(candidate)
          return nil if parent == candidate # reached FS root — nothing existed
          remainder = File.join(File.basename(candidate), remainder)
          candidate = parent
        end
        real = File.realpath(candidate)
        remainder.empty? ? real : File.join(real, remainder)
      rescue Errno::EACCES, Errno::ENOENT
        nil
      end

      def relative_to_workspace(abs)
        abs.sub(File.expand_path(@workspace) + File::SEPARATOR, '')
      end

      def dangerous_command?(cmd)
        Runes::Security::CommandPolicy.dangerous?(cmd)
      end

      # Path tokens that leave the workspace (S4-2/E4-5, hardened in
      # S5-2). Delegates to the shared checker so the dispatcher and
      # bin/runes-mcp can never disagree. Returns the offending token, or
      # nil when every path-shaped token stays inside.
      def command_path_violation?(cmd)
        Runes::Security::CommandPolicy.path_violation(cmd, method(:safe_path))
      end

      # Optional allowlist (RUNES_CMD_ALLOWLIST="ls,cat,git"). When set,
      # the executable token(s) of the command must be on the list.
      # UNSET now means the non-interpreter DEFAULT_ALLOWLIST (S5-2a),
      # not "denylist only" — the old default let `ruby -e <payload>`
      # write anywhere the process could. Interpreters and privileged
      # launchers are refused unless named explicitly, and only then does
      # `ruby -e` become runnable (the documented, deliberate bypass).
      def command_allowlisted?(cmd)
        Runes::Security::CommandPolicy.allowlisted?(
          cmd, allowlist: command_allowlist
        )
      end

      def command_allowlist
        Runes::Security::CommandPolicy.parse_allowlist(@settings.env('RUNES_CMD_ALLOWLIST'))
      end

      def run_in_workspace(cmd)
        cmd = cmd.to_s
        verdict = Runes::Security::CommandPolicy.evaluate(
          cmd,
          allowlist: command_allowlist,
          path_resolver: method(:safe_path)
        )
        return verdict.message if verdict

        timeout_s = Float(@settings.env('RUNES_CMD_TIMEOUT_S') || DEFAULT_CMD_TIMEOUT_S)
        cap = Integer(@settings.env('RUNES_CMD_OUTPUT_CAP') || DEFAULT_OUTPUT_CAP)
        run_confined(cmd, timeout_s, cap)
      rescue ArgumentError
        'Error: invalid RUNES_CMD_TIMEOUT_S or RUNES_CMD_OUTPUT_CAP'
      end

      def run_confined(cmd, timeout_s, cap)
        out = String.new(capacity: 4096)
        truncated = false
        collect = lambda do |io|
          while (chunk = io.read(1024))
            if out.bytesize + chunk.bytesize > cap
              out << chunk.byteslice(0, [cap - out.bytesize, 0].max)
              truncated = true
              break
            end
            out << chunk
          end
        rescue IOError
          nil
        end

        # S-R1: scrub the child environment — provider API keys must
        # never be visible to LLM-planned commands (`env`, `curl ...$KEY`).
        # unsetenv_others makes the passed hash the EXACT child env.
        Open3.popen3(scrubbed_child_env, cmd,
                     chdir: @workspace, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          kill_group = lambda do
            # pgroup: true puts the child in its own process group; the
            # negative pid signals the whole group so grandchildren (e.g.
            # `sh -c 'sleep 5 &'`) cannot survive as orphans.
            Process.kill('KILL', -wait_thr.pid) rescue nil
          end
          t_out = Thread.new { collect.call(stdout) }
          t_err = Thread.new { collect.call(stderr) }
          # Wait in slices so an output-cap kill can preempt the join:
          # a process blocked writing to a full pipe would otherwise hang
          # until the timeout even though we already have enough output.
          finished = nil
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
          loop do
            finished = wait_thr.join(0.1)
            break if finished
            if truncated
              kill_group.call
              finished = wait_thr.join(1)
              break
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              kill_group.call
              wait_thr.join(1)
              # Collector threads may still be blocked on their pipes —
              # stop them deterministically instead of relying on
              # pipe-close IOError (run_confined hardening).
              t_out.kill rescue nil
              t_err.kill rescue nil
              return "Error: command timed out after #{timeout_s}s"
            end
          end
          t_out.join(1)
          t_err.join(1)
          t_out.kill rescue nil
          t_err.kill rescue nil
          status = finished&.value
          return 'Error: command did not terminate cleanly' if status.nil?

          parts = []
          parts << (status.success? ? 'exit=0' : "exit=#{status.exitstatus}")
          parts << "output:\n#{out}" unless out.empty?
          parts << "\n(output truncated at #{cap}B)" if truncated
          parts.join("\n")
        end
      rescue Errno::ENOENT => e
        "Error: #{e.message}"
      end

      # Environment handed to run_command children: provider API keys and
      # other credentials are stripped (S-R1).
      def scrubbed_child_env
        provider_keys = Runes::Core::LLMClient::PROVIDERS.values.flat_map(&:key_envs)
        ENV.to_h.reject do |key, _|
          provider_keys.include?(key) ||
            key.match?(/(API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIALS?)/i)
        end
      end

      # ---------- utilities ----------

      def policy_file_path
        custom = @settings.env('RUNES_POLICY')
        return custom if custom && File.file?(custom)
        File.join(@settings.root, 'config', 'policy.json')
      end

      def safe_parse_args(payload)
        return {} if payload.nil? || payload.to_s.empty?
        parsed = JSON.parse(payload.to_s)
        parsed.is_a?(Hash) ? parsed : { '_raw' => parsed }
      rescue JSON::ParserError
        { '_raw' => payload.to_s }
      end

      # Byte-bounded, encoding-safe prompt truncation (B4-10): String#[]
      # counts CHARACTERS, so a multibyte prompt could exceed
      # MAX_PROMPT_BYTES despite the byte-size check.
      def truncate_prompt(text)
        str = text.to_s
        return str if str.bytesize <= MAX_PROMPT_BYTES

        str.byteslice(0, MAX_PROMPT_BYTES).to_s.scrub
      end

      def log(msg)
        line = "[Dispatcher] #{msg}"
        puts line
        @ui.messages << line if @ui
      end
    end
  end
end
