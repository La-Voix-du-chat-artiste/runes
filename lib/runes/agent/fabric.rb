module Runes
  module Agent
    # Prompt/task subscriptions, A2A discovery, peer cards and
    # cross-dispatcher delegation, extracted from the dispatcher.
    module Fabric
      # Bounds for untrusted peer traffic surfaced locally (S5-6).
      MAX_PEER_REPLY_BYTES = 8 * 1024

      # ---------- identity on the fabric ----------

      def agent_card_topic
        "runes/agents/#{@agent_id}/card"
      end

      def agent_status_topic
        "runes/agents/#{@agent_id}/status"
      end

      def agent_tasks_topic
        "runes/agents/#{@agent_id}/tasks"
      end

      # The legacy card (kept verbatim for the TUI, the observatory and
      # older peers, which read top-level tools/workspace).
      def agent_card
        all_tools = (BUILTIN_TOOLS + @registry.cards.keys).uniq
        {
          'name' => @agent_id,
          'kind' => 'runes.dispatcher',
          'version' => Runes::VERSION,
          'workspace' => @workspace,
          'tools' => all_tools,
          'tools_registered' => @registry.cards.values,
          'wasm_backend' => @vm_manager.backend.to_s,
          'wasm_mock' => @vm_manager.backend == :mock,
          'wasm_boot_error' => @vm_manager.boot_error&.message,
          'started_at' => Time.now.utc.iso8601
        }
      end

      # A2A Agent Card (interoperable field names) with the harness details
      # under `x-runes`; this is what peers and the A2A registry read.
      def a2a_agent_card
        all_tools = (BUILTIN_TOOLS + @registry.cards.keys).uniq
        Runes::A2A::Card.build(
          agent_id: @agent_id,
          name: @agent_id,
          description: 'Runes dispatcher: plans and executes guarded tool calls',
          version: Runes::VERSION,
          url: a2a_task_topic,
          skills: Runes::A2A::Card.skills_from_tools(all_tools, @registry.cards),
          capabilities: { 'streaming' => true, 'pushNotifications' => false },
          extra: {
            'kind' => 'runes.dispatcher',
            'workspace' => @workspace,
            'tools' => all_tools,
            'tools_registered' => @registry.cards.values,
            'wasm_backend' => @vm_manager.backend.to_s,
            'wasm_mock' => @vm_manager.backend == :mock,
            'wasm_boot_error' => @vm_manager.boot_error&.message,
            'started_at' => Time.now.utc.iso8601,
            'org' => @a2a_org,
            'unit' => @a2a_unit
          }
        )
      end

      # Publish the Agent Card as a retained message so observers can
      # discover this dispatcher without polling, and mirror it on the A2A
      # discovery topic with an `a2a-status` presence property.
      def announce_agent_card
        @transport.publish(agent_card_topic, JSON.generate(agent_card), retain: true, qos: 1)
        @transport.publish(agent_status_topic, 'online', retain: true, qos: 1)
        announce_a2a_card
        log "Agent card published at #{agent_card_topic}"
      end

      def announce_a2a_card
        return unless a2a_enabled?

        @transport.publish(
          Runes::A2A.discovery_topic(org: @a2a_org, unit: @a2a_unit, agent_id: @agent_id),
          JSON.generate(a2a_agent_card),
          retain: true, qos: 1,
          properties: { user_properties: Runes::A2A.status_properties('online') }
        )
      rescue => e
        log "A2A card publish failed: #{e.class}: #{e.message}"
      end

      # Work distribution is the TRANSPORT's job now.
      #
      # On MQTT 5 (and the in-process hub) `runes/prompts` is consumed with a
      # SHARED subscription: the broker hands each prompt to exactly one
      # member of the group, which is what the claim/lease protocol used to
      # emulate. MQTT 3.1.1 cannot do that — the transport refuses rather
      # than silently double-delivering — so the agent either refuses to
      # start (RUNES_REQUIRE_SHARED_SUBSCRIPTIONS=1) or runs as the fleet's
      # single consumer, loudly.
      def subscribe_topics
        subscribe_work
        # Delegation is addressed, so it never needs a group.
        @transport.subscribe(agent_tasks_topic, qos: 1) do |message|
          dispatch_prompt { handle_delegated_task(message.payload) }
        end
        @transport.subscribe("#{agent_tasks_topic}/+/response", qos: 1) do |message|
          handle_task_reply(message)
        end

        subscribe_a2a
        subscribe_tool_rpc
      end

      def subscribe_work
        @transport.subscribe(PROMPT_TOPIC, qos: 1, group: prompt_group) do |message|
          dispatch_prompt { handle_incoming_broadcast(message) }
        end
      rescue Runes::Transport::Unsupported => e
        raise if require_shared_subscriptions?

        warn "[Dispatcher] #{e.message}"
        warn '[Dispatcher] falling back to a SINGLE-CONSUMER subscription on ' \
             "#{PROMPT_TOPIC}: run exactly one agent per fleet, or use " \
             'RUNES_TRANSPORT=mqtt5 for shared dispatch (set ' \
             'RUNES_REQUIRE_SHARED_SUBSCRIPTIONS=1 to make this fatal).'
        @transport.subscribe(PROMPT_TOPIC, qos: 1) do |message|
          dispatch_prompt { handle_incoming_broadcast(message) }
        end
      end

      def trust_dir
        @settings.env('RUNES_TRUST_DIR') || File.join(@settings.root, 'config', 'trust')
      end

      # Fail-closed verification: a missing/invalid signature is refused and
      # answered, never executed. Returns the VERIFIED payload (sig/alg/kid
      # stripped) so callers cannot fall back to their own pre-verification
      # parse (S5-1); nil means the message was refused and answered.
      # A process-wide replay guard: the nonce of every envelope we accept is
      # remembered for a window, so a captured signed envelope cannot be
      # replayed (doc5.md S5-4 / E5-13). `RUNES_REQUIRE_FRESHNESS=1` also
      # refuses envelopes that carry no ts/nonce at all — off by default so a
      # peer running an older build still interoperates.
      REPLAY_GUARD = Runes::Security::NonceCache.new

      def self.replay_guard
        REPLAY_GUARD
      end

      def verify_signed!(message, reply_topic)
        raw = message.respond_to?(:payload) ? message.payload : message
        data = safe_parse_args(raw)
        Runes::Security::Envelope.verify!(
          data, @trust_store,
          require_fresh: @require_freshness,
          replay_guard: REPLAY_GUARD
        )
      rescue Runes::Security::EnvelopeError => e
        reason = e.respond_to?(:reason) ? e.reason : :malformed
        warn "[Dispatcher] rejected envelope: #{e.message}"
        publish_result(@transport, reply_topic, "Error: unsigned or invalid envelope (#{reason})")
        nil
      end

      # The single admission point for every inbound prompt path (S5-1).
      # When signatures are required the payload is verified FIRST and only
      # the verified bytes are yielded to the caller's parser; a future
      # subscription cannot forget the gate because the payload is
      # unreachable without calling this method. Returns the block's value,
      # or nil when the message was refused and answered on `reply_topic`.
      def admitted_payload(raw, reply_topic)
        if @require_signatures
          verified = verify_signed!(raw, reply_topic)
          return nil if verified.nil?

          yield JSON.generate(verified)
        else
          yield(raw.respond_to?(:payload) ? raw.payload : raw)
        end
      end

      # A reply topic is attacker-influenced: it arrives in the MQTT 5
      # Response Topic property (or an envelope field) and is used as a
      # publish target. Require our namespace, reject wildcards and
      # `$`-topics, and bound the length (S5-5/E5-18).
      def valid_reply_topic?(topic)
        text = topic.to_s
        return false if text.empty? || text.bytesize > 256
        return false unless text.start_with?('runes/')
        return false if text.include?('+') || text.include?('#') || text.include?("\0")
        return false if text.split('/').any?(&:empty?)

        true
      end

      def safe_reply_topic(topic)
        text = topic.to_s
        valid_reply_topic?(text) ? text : nil
      end

      # Peer task replies are surfaced on the fleet response channel. Bound
      # and sanitize them first so a hostile peer cannot reflect an
      # arbitrary payload into it verbatim (S5-6).
      def sanitized_peer_reply(payload)
        text = payload.to_s
        text = text.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
        text = text.gsub(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/, '')
        text.bytesize > MAX_PEER_REPLY_BYTES ? text.byteslice(0, MAX_PEER_REPLY_BYTES) + '…' : text
      end

      def require_shared_subscriptions?
        %w[1 true yes on].include?(@settings.env('RUNES_REQUIRE_SHARED_SUBSCRIPTIONS').to_s.downcase)
      end

      def prompt_group
        @settings.env('RUNES_PROMPT_GROUP') || DEFAULT_PROMPT_GROUP
      end

      # A2A-over-MQTT: peer cards are retained on the standard discovery
      # topic, and addressed tasks arrive on the A2A task topic.
      def subscribe_a2a
        return unless a2a_enabled?

        @transport.subscribe(Runes::A2A.discovery_wildcard(@a2a_org), qos: 1) do |message|
          record_peer_card(message)
        end
        @transport.subscribe(Runes::A2A.task_wildcard(@a2a_org, @a2a_unit), qos: 1) do |message|
          dispatch_prompt { handle_a2a_task(message) }
        end
      end

      def subscribe_tool_rpc
        return unless tool_rpc_enabled?

        @transport.subscribe('runes/tools/+/request', qos: 1) do |message|
          tool_id = message.topic.split('/')[2].to_s
          dispatch_tool_request(tool_id, message.payload)
        end
      end

      def a2a_enabled?
        !%w[0 false no off].include?(@settings.env('RUNES_A2A').to_s.downcase)
      end

      def a2a_task_topic
        Runes::A2A.task_topic(org: @a2a_org, unit: @a2a_unit, agent_id: @agent_id)
      end

      # A prompt arrived on the shared broadcast subscription: parse it and
      # route. Reply routing prefers the MQTT 5 Response Topic property and
      # falls back to the conventional correlated topic. The provisional
      # parse only derives that topic; execution uses the admitted envelope.
      def handle_incoming_broadcast(message)
        provisional = parse_envelope(message.payload)
        reply_topic = safe_reply_topic(message.response_topic) ||
                      (provisional[:from_envelope] ? "runes/prompts/#{provisional[:request_id]}/response" : nil)
        admitted_payload(message, reply_topic) do |payload|
          env = parse_envelope(payload)
          env[:verified] = true
          handle_prompt(@transport, env, reply_topic: reply_topic)
        end
      end

      # ---------- cross-dispatcher delegation ----------


      # Send a task to a peer by naming its agent id (addressed topic) and,
      # when A2A is enabled, also offer it on the peer's A2A task topic with
      # Response Topic/Correlation Data so non-Runes peers can reply the
      # standard way.
      def delegate_to(publisher, peer_agent_id, prompt, request_id: nil, a2a: false)
        request_id = sanitize_request_id(request_id || SecureRandom.uuid[0, 8])
        reply_topic = "runes/agents/#{@agent_id}/tasks/#{request_id}/response"
        payload = {
          'prompt' => prompt,
          'from' => @agent_id,
          'request_id' => request_id,
          'at' => Time.now.utc.iso8601
        }
        payload = Runes::Security::Envelope.sign(payload, @identity, fresh: true) if @require_signatures
        envelope = JSON.generate(payload)
        publisher.publish("runes/agents/#{peer_agent_id}/tasks", envelope,
                          qos: 1,
                          properties: { response_topic: reply_topic, correlation_id: request_id })
        if a2a && a2a_enabled?
          task = Runes::A2A::Task.request(prompt: prompt, task_id: request_id)
          publisher.publish(Runes::A2A.task_topic(org: @a2a_org, unit: @a2a_unit, agent_id: peer_agent_id),
                            a2a_task_payload(task, request_id), qos: 1,
                            properties: { response_topic: reply_topic, correlation_id: request_id })
        end
        log "Delegated task to #{peer_agent_id} (request=#{request_id})"
        request_id
      end

      # When signatures are required an A2A task (which contains arrays and
      # is therefore not canonicalisable) travels as the `a2a` JSON string
      # inside a signed runes envelope. Unsigned mode keeps the bare profile
      # task so non-Runes A2A peers interoperate.
      def a2a_task_payload(task, request_id)
        return JSON.generate(task) unless @require_signatures

        JSON.generate(
          Runes::Security::Envelope.sign(
            { 'a2a' => JSON.generate(task), 'request_id' => request_id.to_s }, @identity, fresh: true
          )
        )
      end

      def handle_delegated_task(payload)
        admitted_payload(payload, nil) do |raw|
          env = safe_parse_args(raw)
          prompt = env['prompt'] || env['_raw'].to_s
          reply_topic = delegation_reply_topic(env)
          inner = parse_envelope(prompt.to_s)
          # The delegation envelope's `request_id` is verified and already
          # decides the reply topic; when the delegation carried a plain
          # prompt, the inner envelope has no identity of its own, so adopt the
          # outer one. Without this a redelivered delegation could not be
          # deduped (and its progress would key off a text digest instead of
          # the request the peer is waiting on).
          unless inner[:from_envelope]
            delegated_id = env['request_id'].to_s
            if delegated_id.match?(REQUEST_ID_RE)
              inner[:request_id] = delegated_id
              # Dedupe identity, NOT `from_envelope`: that flag also derives a
              # conventional reply topic, and an unsafe `from` must keep its
              # reply suppressed (D10). Progress and journal correlation follow
              # the delegation's request id, which is what the peer waits on.
              inner[:dedupe_key] = Runes::RequestLedger.prompt_key(delegated_id)
            end
          end
          inner[:verified] = true
          handle_prompt(@transport, inner, reply_topic: reply_topic)
        end
      end

      # The delegation reply topic is derived from the VERIFIED payload
      # only (never from the pre-verification parse): both fields become
      # MQTT fragments, so an invalid `from`/`request_id` suppresses the
      # reply entirely.
      def delegation_reply_topic(env)
        from = env['from'].to_s
        req = env['request_id'].to_s
        return nil unless from.match?(AGENT_ID_RE) && req.match?(REQUEST_ID_RE)

        "runes/agents/#{from}/tasks/#{req}/response"
      end

      def handle_task_reply(message)
        # The subscription is `runes/agents/<id>/tasks/+/response`, but
        # check the topic shape anyway: a re-subscribe mistake must not let
        # a peer's reply be surfaced as another agent's (S5-6).
        match = TASK_REPLY_PATTERN.match(message.topic.to_s)
        if match.nil? || match[1] != @agent_id
          log "Ignoring a task reply on an unexpected topic #{message.topic.inspect}."
          return
        end

        payload = safe_parse_args(message.payload)
        req = message.correlation_id || payload['request_id']
        # The payload is still peer-controlled: sanitize and bound it
        # before surfacing (S5-6).
        summary = sanitized_peer_reply(message.payload)
        publish_result(@transport, nil, "[delegate #{match[1]}/#{req}] #{summary}")
      end

      # An A2A task arrived on the standard task topic: run it and answer on
      # the Response Topic the sender asked for, with an `a2a-status` user
      # property so a peer can track progress without reading our payloads.
      def handle_a2a_task(message)
        reply_topic = safe_reply_topic(message.response_topic)
        admitted_payload(message, reply_topic) do |raw|
          task = a2a_task_from(raw)
          if task.nil?
            log 'Ignoring malformed A2A task.'
            next
          end

          env = Runes::A2A::Task.to_envelope(task, mode: task.dig('metadata', 'mode') || 'build')
          env[:verified] = true
          reply_topic ||= "runes/prompts/#{env[:request_id]}/response"
          @transport.publish(reply_topic, JSON.generate(Runes::A2A::Task.status(state: 'working')),
                             qos: 1,
                             properties: { response_topic: reply_topic,
                                           correlation_id: env[:request_id].to_s,
                                           user_properties: Runes::A2A.status_properties('working') })
          handle_prompt(@transport, env, reply_topic: reply_topic)
        end
      end

      # A verified payload is a bare A2A task in unsigned mode and a signed
      # envelope carrying the task JSON under `a2a` otherwise.
      def a2a_task_from(raw)
        data = safe_parse_args(raw)
        if @require_signatures
          body = data['a2a'].to_s
          return nil if body.empty?

          Runes::A2A::Task.parse(body)
        else
          Runes::A2A::Task.parse(raw)
        end
      end

      # Peer cards arrive retained on the A2A discovery topic; keep a bounded
      # registry so an agent can discover who else is on the fabric.
      def record_peer_card(message)
        card = Runes::A2A::Card.parse(message.payload)
        return if card.nil?

        agent_id = Runes::A2A.agent_id_from_discovery(message.topic)
        return if agent_id.nil? || agent_id == @agent_id
        # The card is unauthenticated (discovery-only impact), but the id
        # comes from the topic and becomes a row in peer state: accept only
        # ids that satisfy the same grammar we enforce on ourselves (S5-6).
        return unless agent_id.match?(AGENT_ID_RE)

        @peers_mutex.synchronize do
          @peers.shift while @peers.size >= MAX_PEERS && !@peers.key?(agent_id)
          @peers[agent_id] = {
            agent_id: agent_id,
            name: Runes::A2A::Card.name_of(card),
            skills: Runes::A2A::Card.skills_of(card).map { |skill| skill['id'] }.compact,
            status: Runes::A2A.status_from(message.properties) || 'online',
            seen_at: Time.now
          }
        end
      end

      def peers
        @peers_mutex.synchronize { @peers.values.dup }
      end
    end
  end
end
