require 'net/http'
require 'json'
require 'uri'

module Runes
  module Core
    # Multi-provider router for planner LLMs. Every supported provider is
    # OpenAI-compatible (/chat/completions); the PROVIDERS registry maps a
    # provider name to its endpoint, key env vars, model aliases and the
    # strategy used to express a "variation":
    #
    #   * :temperature      -> temperature 0.7 (high) / 0.2 (low|balanced)
    #   * :reasoning_effort -> reasoning_effort low|high|max (Synthetic GLM)
    #
    # Resolution order for provider/model/variation:
    #   explicit call arg > RUNES_DEFAULT_* env > settings DB > provider default.
    # If the preferred provider has no API key configured but another
    # registered provider does, the router falls through with a notice
    # (opt out with RUNES_ALLOW_PROVIDER_FALLBACK=0 — S-L2).
    class LLMClient
      # Reasoning models at high effort can take minutes to plan; keep
      # the HTTP window generous and env-tunable. Evaluated lazily (L3):
      # a malformed RUNES_LLM_TIMEOUT_S must not crash boot, and tests /
      # settings must be able to adjust it.
      DEFAULT_HTTP_TIMEOUT_S = 180

      # Retry budget: 4 attempts x 180s could block a worker ~12 minutes;
      # cap the TOTAL wall clock across attempts (enhancement).
      TOTAL_ATTEMPT_BUDGET_MULTIPLIER = 1.5

      # Cap on untrusted provider output parsed as JSON (S-L3).
      MAX_RESPONSE_BYTES = 1024 * 1024
      # Provider error bodies are echoed into MQTT/journal — bound and
      # sanitize them (S-L1).
      MAX_ERROR_BODY_CHARS = 500

      MAX_NOTICES = 100

      Provider = Struct.new(:name, :base_url, :key_envs, :default_model,
                            :seed_model, :model_prefix, :aliases, :sampling,
                            keyword_init: true)

      # Registry order is meaningful: PROVIDER_PREFERENCE below is derived
      # from it, and that order decides which keyed provider is used when
      # the preferred one has no key (and which one seeds a fresh DB).
      #
      # DeepSeek first (V4.1 Flash), then Synthetic (GLM), then Cerebras.
      PROVIDERS = {
        'deepseek' => Provider.new(
          name: 'deepseek',
          # OpenAI-compatible surface; the client appends /chat/completions.
          base_url: 'https://api.deepseek.com/v1',
          key_envs: %w[DEEPSEEK_API_KEY DEEPSEEK],
          default_model: 'deepseek-flash', # DeepSeek-V4.1-Flash (released 2026-09-10)
          seed_model: 'deepseek-flash',
          model_prefix: 'deepseek',
          aliases: {
            'deepseek'            => 'deepseek-flash',
            'deepseek-flash'      => 'deepseek-flash',
            'v4.1-flash'          => 'deepseek-flash',
            'deepseek-v4.1-flash' => 'deepseek-flash',
            'deepseek-v4-flash'   => 'deepseek-flash', # retired name, still routed
            'deepseek-v4-pro'     => 'deepseek-flash', # retiring; routed to V4.1 Flash
            'flash'               => 'deepseek-flash'
          },
          # Thinking mode is on by default; OpenAI-format effort is
          # low|high|max (medium/xhigh fold to high, ultra/minimal fold
          # per the provider's own mapping table).
          sampling: :reasoning_effort
        ),
        'synthetic' => Provider.new(
          name: 'synthetic',
          base_url: 'https://api.synthetic.new/openai/v1',
          key_envs: %w[SYNTHETIC_API_KEY SYNTHETIC],
          default_model: 'syn:large:text', # zai-org/GLM-5.3-Flash
          seed_model: 'glm-5.3-flash',     # friendly alias; mapped at call time
          model_prefix: 'syn:',
          aliases: {
            'glm-5.3-flash' => 'syn:large:text',
            'glm'           => 'syn:large:text',
            'glm-4.7-flash' => 'syn:small:text'
          },
          sampling: :reasoning_effort
        ),
        'cerebras' => Provider.new(
          name: 'cerebras',
          base_url: 'https://api.cerebras.ai/v1',
          key_envs: %w[CEREBRAS_API_KEY CEREBRAS],
          default_model: 'llama-3.3-70b',
          seed_model: 'llama-3.3-70b',
          model_prefix: 'llama',
          aliases: {},
          sampling: :temperature
        )
      }.freeze

      # Documented preference order: DeepSeek (V4.1 Flash, high effort),
      # then Synthetic, then Cerebras. Used for key-based fallback and for
      # seeding `default_provider` on a fresh preferences DB.
      PROVIDER_PREFERENCE = PROVIDERS.keys.freeze

      Route = Struct.new(:provider, :base_url, :model, :variation,
                         :sampling_params, :api_key, keyword_init: true)

      def self.provider_names
        PROVIDERS.keys
      end

      # Model used when seeding a fresh preferences DB for `provider`.
      def self.seed_model_for(provider)
        PROVIDERS[provider.to_s]&.seed_model
      end

      # Injectable HTTP transport. The default talks to the provider over
      # Net::HTTP; tests inject a fake transport (a "dup" of the real call
      # path) so the suite never needs an API key or network access. A
      # transport must respond to:
      #   post(uri:, route:, body:, timeout_s:) -> a Net::HTTPResponse-like
      #   object (responds to #code, #body, #[]), or raise a timeout.
      class HTTPTransport
        def post(uri:, route:, body:, timeout_s:)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.is_a?(URI::HTTPS)
          http.read_timeout = timeout_s
          http.open_timeout = timeout_s
          http.write_timeout = timeout_s if http.respond_to?(:write_timeout=)

          request = Net::HTTP::Post.new(uri.path, {
            'Content-Type'  => 'application/json',
            'Authorization' => "Bearer #{route.api_key}"
          })
          request.body = body
          http.request(request)
        end
      end

      def initialize(settings, transport: nil)
        @settings = settings
        @transport = transport || HTTPTransport.new
        @notices = []
        @notices_mutex = Mutex.new
      end

      # Notices accumulated during routing (model re-derivation, provider
      # fallback). Returns a bounded dup under the lock — the raw array
      # must never leak to concurrent readers (L5).
      def notices
        @notices_mutex.synchronize { @notices.dup }
      end

      # @param prompt [String] the user's natural-language prompt
      # @param provider [String, nil] planner backend ('cerebras', 'synthetic', ...)
      # @param model [String, nil] provider model id or friendly alias
      # @param variation [String, nil] 'high' | 'balanced' | 'low' | 'max'
      # @param tools [Array<Hash>, nil] OpenAI-style function schemas. When
      #   non-nil, send them via the `tools` field and expect the model to
      #   return one or more tool_calls instead of a free-form plan.
      #
      # @return [Hash] one of:
      #   { ok: true, mode: :content,    content: String,  raw: Hash,
      #     provider: String, model: String }
      #   { ok: true, mode: :tool_calls, tool_calls: Array, raw: Hash,
      #     provider: String, model: String }
      #   { ok: false, error: String }
      def call(prompt, provider: nil, model: nil, variation: nil, tools: nil)
        route = resolve_route(provider: provider, model: model, variation: variation)
        return err(last_notice) if route.nil?

        result = call_openai_compatible(route, prompt, tools: tools)
        result[:provider] = route.provider
        result[:model]    = route.model
        result
      end

      # Multi-turn conversation (goal/plan modes). `messages` is an Array
      # of {role, content} hashes (user/assistant turns); `system` is
      # prepended when given.
      def chat(messages, system: nil, json: false, variation: nil, tools: nil)
        # Array(messages) on a Hash yields key/value pairs and explodes
        # confusingly later (L7) — validate the shape up front.
        unless messages.is_a?(Array) && messages.all? { |m| m.is_a?(Hash) }
          return err('messages must be an Array of {role, content} hashes')
        end

        route = resolve_route(variation: variation)
        return err(last_notice) if route.nil?

        result = call_openai_compatible(route, messages, tools: tools, system: system, json: json)
        result[:provider] = route.provider
        result[:model]    = route.model
        result
      end

      # Pure routing logic (no I/O) — resolves provider, model, variation
      # and sampling params. Returns a Route, or nil when no provider can
      # be reached (reason in the last notice).
      def resolve_route(provider: nil, model: nil, variation: nil)
        p_name = resolve_provider(provider)
        return nil unless p_name

        p_def  = PROVIDERS[p_name]
        model  = resolve_model(p_name, model)
        var    = resolve_variation(variation)

        Route.new(
          provider: p_name,
          base_url: p_def.base_url,
          model: model,
          variation: var,
          sampling_params: sampling_params(p_def, var),
          api_key: api_key_for(p_name)
        )
      end

      # Build the OpenAI-compatible request payload (pure — unit tested).
      # `prompt` is either a String (single user turn) or an Array of
      # {role, content} message hashes. `json: true` adds response_format
      # json_object (default for the legacy one-shot planner).
      def build_payload(route, prompt, tools: nil, system: nil, json: true)
        messages =
          if prompt.is_a?(Array)
            msgs = prompt.map { |m| { 'role' => m['role'] || m[:role], 'content' => m['content'] || m[:content] } }
            msgs.unshift({ 'role' => 'system', 'content' => system }) if system
            msgs
          else
            sys = system || (tools ? tool_mode_system_prompt : planner_system_prompt)
            [{ 'role' => 'system', 'content' => sys }, { 'role' => 'user', 'content' => prompt }]
          end

        payload = {
          model: route.model,
          messages: messages
        }
        payload.merge!(route.sampling_params || {})
        # Optional output cap. Unset keeps the provider default (which is
        # what silently governed truncation/cost before this knob existed).
        payload[:max_tokens] = max_tokens if max_tokens&.positive?

        if tools.nil?
          # Legacy free-form planner: ask for strict JSON.
          payload[:response_format] = { type: 'json_object' } if json
        else
          # Function-calling mode.
          payload[:tools] = tools
          payload[:tool_choice] = 'auto'
        end
        payload
      end

      # Convenience: the function schemas that represent our builtins +
      # any tools/ entries. Returns Array<Hash> ready for the `tools` field.
      def self.builtin_schemas(extra: [])
        base = [
          {
            type: 'function',
            function: {
              name: 'write_file',
              description: 'Write content to a workspace-relative file.',
              parameters: {
                type: 'object',
                properties: {
                  path:    { type: 'string', description: 'Workspace-relative file path.' },
                  content: { type: 'string', description: 'Content to write.' }
                },
                required: %w[path content]
              }
            }
          },
          {
            type: 'function',
            function: {
              name: 'read_file',
              description: 'Read the contents of a workspace-relative file.',
              parameters: {
                type: 'object',
                properties: {
                  path: { type: 'string' }
                },
                required: %w[path]
              }
            }
          },
          {
            type: 'function',
            function: {
              name: 'run_command',
              description: 'Run a shell command in the workspace. Shell metacharacters and destructive verbs are blocked.',
              parameters: {
                type: 'object',
                properties: {
                  cmd: { type: 'string' }
                },
                required: %w[cmd]
              }
            }
          }
        ]
        base + Array(extra).reject { |schema| duplicate_tool_name?(schema, base) }
      end

      # A tool name may appear only ONCE in a request: the shipped tools/
      # directory also carries manifests for the builtins, and providers
      # reject duplicates (DeepSeek: HTTP 400 "Tool names must be unique").
      def self.duplicate_tool_name?(schema, base)
        return true unless schema.is_a?(Hash)

        name = schema.dig(:function, :name) || schema.dig('function', 'name')
        return true if name.nil?

        base.any? do |known|
          known_name = known.dig(:function, :name) || known.dig('function', 'name')
          known_name == name
        end
      end

      private

      # --- Routing --------------------------------------------------------

      def resolve_provider(explicit)
        preferred = []
        preferred << explicit.to_s.strip.downcase if explicit && !explicit.to_s.strip.empty?
        if (e = @settings.env('RUNES_DEFAULT_PROVIDER')) && !e.strip.empty?
          preferred << e.strip.downcase
        elsif (db = @settings.get('default_provider')) && !db.to_s.strip.empty?
          preferred << db.to_s.strip.downcase
        end

        # An explicitly-configured provider that is not in the registry is
        # a configuration error — fail loudly rather than silently rerouting.
        preferred.each do |name|
          unless PROVIDERS.key?(name)
            notice("unsupported provider: #{name} (available: #{PROVIDERS.keys.join(', ')})")
            return nil
          end
        end

        preferred.each do |name|
          return name if api_key_for(name)
        end

        # Preferred provider(s) lack a key: fall through to any registered
        # provider that does have one — unless the operator opted out
        # (S-L2: silent cross-provider routing can leak prompts to an
        # unintended third party).
        if provider_fallback_allowed?
          fallback = PROVIDER_PREFERENCE.find { |name| api_key_for(name) }
          if fallback
            notice("no API key for #{preferred.join('/')} — falling back to '#{fallback}' " \
                   "(preference order: #{PROVIDER_PREFERENCE.join(' > ')})")
            return fallback
          end
        else
          notice("no API key for #{preferred.join('/')} and provider fallback is disabled " \
                 '(unset RUNES_ALLOW_PROVIDER_FALLBACK to allow)')
          return nil
        end

        notice("no LLM provider key found (checked: #{PROVIDERS.values.flat_map(&:key_envs).join(', ')})")
        nil
      end

      def provider_fallback_allowed?
        val = @settings.env('RUNES_ALLOW_PROVIDER_FALLBACK').to_s.downcase
        !%w[0 false no off].include?(val)
      end

      def resolve_model(p_name, model_param)
        p_def = PROVIDERS[p_name]
        raw = model_param
        raw = env_or_settings('RUNES_DEFAULT_MODEL', 'default_model') if raw.nil? || raw.to_s.strip.empty?
        raw = raw.to_s.strip

        return p_def.default_model if raw.empty?
        return p_def.aliases[raw.downcase] if p_def.aliases.key?(raw.downcase)
        return raw if raw.downcase.start_with?(p_def.model_prefix)

        # Unknown model for this provider (e.g. a Cerebras model name left
        # in the DB while routing to Synthetic) — re-derive the default.
        notice("model '#{raw}' is not known for provider '#{p_name}' — using #{p_def.default_model}")
        p_def.default_model
      end

      def resolve_variation(variation)
        v = variation
        v = env_or_settings('RUNES_DEFAULT_VARIATION', 'default_variation') if v.nil? || v.to_s.strip.empty?
        v = v.to_s.strip.downcase
        v.empty? ? 'high' : v
      end

      def sampling_params(p_def, variation)
        case p_def.sampling
        when :temperature
          { temperature: variation == 'high' ? 0.7 : 0.2 }
        when :reasoning_effort
          # DeepSeek accepts low|high|max and folds medium/xhigh to high,
          # minimal to low, ultra to max; Synthetic accepts low|high|max.
          # Anything we do not recognise is treated as the low end, which is
          # the cheap/fast direction for a format-conversion call.
          effort = case variation.to_s
                   when 'max', 'ultra' then 'max'
                   when 'high', 'xhigh', 'medium' then 'high'
                   else 'low'
                   end
          { reasoning_effort: effort }
        else
          {}
        end
      end

      def api_key_for(p_name)
        p_def = PROVIDERS[p_name]
        return nil unless p_def
        key = p_def.key_envs.map { |env| @settings.env(env) }.compact.find { |k| !k.to_s.strip.empty? }
        key&.strip
      end

      def env_or_settings(env_var, settings_key)
        if (e = @settings.env(env_var)) && !e.strip.empty?
          e
        else
          @settings.get(settings_key)
        end
      end

      def notice(message)
        @notices_mutex.synchronize do
          @notices << message
          @notices.shift while @notices.size > MAX_NOTICES
        end
        warn("runes[llm] #{message}") if ENV['RUNES_DEBUG']
        message
      end

      # Concurrent prompt workers share this client; notices are read
      # under the same lock that guards writes.
      def last_notice
        @notices_mutex.synchronize { @notices.last }
      end

      # --- HTTP -----------------------------------------------------------

      def http_timeout_s
        raw = @settings.env('RUNES_LLM_TIMEOUT_S')
        return DEFAULT_HTTP_TIMEOUT_S if raw.nil? || raw.to_s.strip.empty?
        Float(raw)
      rescue ArgumentError
        DEFAULT_HTTP_TIMEOUT_S
      end

      def call_openai_compatible(route, prompt, tools: nil, system: nil, json: true)
        p_name = route.provider
        uri = URI.parse("#{route.base_url}/chat/completions")

        payload = build_payload(route, prompt, tools: tools, system: system, json: json)
        body = payload.to_json

        response = request_with_retry(route, uri, body)
        if response.nil?
          return err("#{p_name} request failed after #{MAX_RETRIES + 1} attempts " \
                     "(timeout or connection error; #{http_timeout_s}s per attempt window)")
        end

        parsed = safe_parse_json(response.body)

        unless successful_response?(response)
          msg = error_message(parsed, response)
          return err("#{p_name} HTTP #{response.code}: #{sanitize_error_body(msg)}")
        end

        return err("#{p_name} response too large to parse (#{response.body.to_s.bytesize}B)") if parsed.nil? && too_large?(response.body)

        message = parsed.is_a?(Hash) ? parsed.dig('choices', 0, 'message') : nil
        return err("#{p_name} response missing choices[0].message") if message.nil?

        # A length-truncated response silently yields corrupt plans (L2 /
        # enhancement): surface finish_reason=length as an explicit error.
        if parsed.is_a?(Hash) && parsed.dig('choices', 0, 'finish_reason') == 'length'
          return err("#{p_name} response was truncated (finish_reason=length) — raise max_tokens or shorten the prompt")
        end

        if (tcs = message['tool_calls']) && !tcs.empty?
          calls = tcs.map do |tc|
            raw_args = tc.dig('function', 'arguments')
            # Some providers deliver already-parsed objects, not strings.
            if raw_args.is_a?(Hash)
              parsed_args = raw_args
              malformed = false
            else
              raw_args = raw_args.to_s
              parsed_args = safe_parse_json(raw_args)
              # L2, fail closed: malformed/truncated args must never be
              # executed as an empty-args step — the whole planner
              # response is treated as corrupt (this is almost always a
              # max_tokens truncation mid-arguments).
              malformed = parsed_args.nil? && !raw_args.strip.empty?
            end
            if malformed
              notice("tool call '#{tc.dig('function', 'name')}' had unparseable arguments " \
                     "(#{raw_args.bytesize}B) — refusing to execute")
              return err("#{p_name} tool call '#{tc.dig('function', 'name')}' had unparseable arguments " \
                         '(truncated or malformed) — planner output rejected')
            end
            {
              id: tc['id'],
              tool: tc.dig('function', 'name'),
              args: parsed_args || {}
            }
          end
          return { ok: true, mode: :tool_calls, tool_calls: calls, raw: parsed,
                   usage: usage_of(parsed), finish_reason: finish_reason_of(parsed) }
        end

        content = message['content']
        return err("#{p_name} response has neither content nor tool_calls") if content.nil?

        { ok: true, mode: :content, content: content, raw: parsed,
          usage: usage_of(parsed), finish_reason: finish_reason_of(parsed) }
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        err("#{p_name} request timed out: #{e.message}")
      rescue => e
        err("#{p_name} request failed: #{e.class}: #{e.message}")
      end

      RETRYABLE_CODES = %w[429 500 502 503 504].freeze
      MAX_RETRIES     = 3

      # Retry transient provider failures (rate limit, 5xx, network
      # timeouts) with exponential backoff. Never raises; returns the
      # final response or nil when every attempt timed out.
      #
      # A FRESH connection is built per attempt (L4): after a read
      # timeout the same Net::HTTP can consume a late response from the
      # previous attempt as the retry's body. Total wall clock is capped
      # at ~1.5x the per-attempt timeout (enhancement).
      def request_with_retry(route, uri, body)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + http_timeout_s * TOTAL_ATTEMPT_BUDGET_MULTIPLIER
        response = nil
        (MAX_RETRIES + 1).times do |attempt|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if attempt.positive? && remaining <= 0

          response = attempt_request(uri, route, body, [http_timeout_s, remaining].min)
          transient = response.nil? || RETRYABLE_CODES.include?(response.code)
          break unless transient
          break if attempt == MAX_RETRIES

          sleep(retry_after_seconds(response) || retry_backoff_s * (2**attempt))
        end
        response
      end

      # Connection-level failures (as opposed to a provider HTTP error) are
      # retried on a FRESH connection: a reset/refused socket is usually
      # transient, and before this only timeouts were retried (E4-12).
      TRANSIENT_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
        Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE,
        Errno::EHOSTUNREACH, EOFError, SocketError, IOError
      ].freeze

      def attempt_request(uri, route, body, timeout_s)
        @transport.post(uri: uri, route: route, body: body, timeout_s: timeout_s)
      rescue *TRANSIENT_ERRORS
        nil
      end

      # Base retry backoff (exponential). Tests set RUNES_RETRY_BACKOFF_S=0
      # so retry paths are exercised without paying for sleeps.
      def retry_backoff_s
        raw = @settings.env('RUNES_RETRY_BACKOFF_S')
        return 0.5 if raw.nil? || raw.to_s.strip.empty?

        Float(raw)
      rescue ArgumentError
        0.5
      end

      # Honor a provider Retry-After hint (seconds or HTTP-date) instead
      # of only fixed backoff (enhancement). Capped to keep workers sane.
      def retry_after_seconds(response)
        return nil unless response.respond_to?(:[]) && response['retry-after']
        raw = response['retry-after'].to_s.strip
        return nil if raw.empty?
        return [Float(raw), 30.0].min if raw.match?(/\A\d+(\.\d+)?\z/)
        if (t = (Time.httpdate(raw) rescue nil))
          [(t - Time.now).clamp(0, 30), 0.5].max
        end
      rescue ArgumentError
        nil
      end

      # Provider error bodies are interpolated into MQTT publications and
      # the durable journal (S-L1): truncate and strip control characters
      # so a hostile endpoint cannot spray arbitrary content.
      def sanitize_error_body(msg)
        clean = msg.to_s.gsub(/[\x00-\x08\x0b-\x1f\x7f]/, ' ')
        clean = clean[0, MAX_ERROR_BODY_CHARS] + '…' if clean.length > MAX_ERROR_BODY_CHARS
        clean
      end

      # Provider error bodies are not shape-stable: OpenAI returns
      # {"error":{"message":...}}, several gateways return {"error":"..."}
      # (a bare string), some return {"message":"..."} or plain text.
      # Assuming an object here used to raise TypeError and mask every
      # provider failure as "request failed: TypeError" (B4-2 / E4-9).
      def error_message(parsed, response)
        obj = parsed.is_a?(Hash) ? parsed['error'] : nil
        case obj
        when Hash
          obj['message'] || obj['type'] || obj.to_json
        when String, Numeric, TrueClass, FalseClass
          obj.to_s
        when Array
          obj.map(&:to_s).join(', ')
        else
          if parsed.is_a?(Hash)
            parsed['message'] || parsed['detail'] || response.body
          else
            response.body
          end
        end
      end

      # A response is successful if it is a real Net::HTTPSuccess or a
      # duck-typed stand-in that says so (injected test transports).
      def successful_response?(response)
        return true if response.is_a?(Net::HTTPSuccess)

        response.respond_to?(:success?) && response.success?
      end

      def usage_of(parsed)
        parsed.is_a?(Hash) ? parsed['usage'] : nil
      end

      def finish_reason_of(parsed)
        parsed.is_a?(Hash) ? parsed.dig('choices', 0, 'finish_reason') : nil
      end

      # RUNES_MAX_TOKENS (optional): bound completion size. Unset keeps the
      # provider default; malformed values are ignored rather than fatal.
      def max_tokens
        raw = @settings.env('RUNES_MAX_TOKENS')
        return nil if raw.nil? || raw.to_s.strip.empty?

        Integer(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def too_large?(str)
        str.to_s.bytesize > MAX_RESPONSE_BYTES
      end

      def planner_system_prompt
        <<~PROMPT
          You are a planner for a tool-executing agent. Decompose the user's
          request into a sequence of tool calls. Available tools:

            - write_file(path, content)     write content to path (relative to workspace)
            - read_file(path)               return file contents
            - run_command(cmd)              run a shell command in the workspace

          Respond with STRICT JSON of the form:
            {"steps":[{"tool":"write_file","args":{"path":"...","content":"..."}},
                      {"tool":"run_command","args":{"cmd":"..."}}]}

          Do NOT include explanations. Do NOT use markdown code fences.
          Do NOT invoke tools that don't exist. Use relative paths only.
        PROMPT
      end

      def tool_mode_system_prompt
        <<~PROMPT
          You are a planner for a tool-executing agent that runs exactly ONE
          turn: the tool calls you emit now are the only ones that will ever
          run. Emit the COMPLETE ordered sequence in a single response,
          including any run_command the user asks for. Assume every earlier
          step succeeds; you will not get a chance to inspect results. A
          response that omits a requested step is wrong. Use
          workspace-relative paths only, and do not invent tools.
        PROMPT
      end

      def safe_parse_json(str)
        str = str.to_s
        return nil if str.bytesize > MAX_RESPONSE_BYTES
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def err(message)
        { ok: false, error: message }
      end

      # ---------- goal / mission prompts ----------

      GOAL_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are helping a developer shape a product need into a clear epic.
        Ask at most one short question per turn and only when a decision is
        genuinely missing (users, scope, constraints, success). Reflect what
        you already know instead of re-asking. When the picture is complete,
        say what is still open rather than inventing facts. Keep replies
        under 150 words.
      PROMPT

      MISSION_SYSTEM_PROMPT = <<~PROMPT.freeze
        You convert a requirement into an executable mission.
        Respond with STRICT JSON only, no markdown fences, no prose:
          {"mission_title": "...",
           "todos": [{"id": 1, "title": "...", "detail": "...",
                      "acceptance": "how we verify it is done"}]}
        Rules: 3 to 9 todos; ordered so value ships early; each title is an
        outcome ("X works/exists"), not a task verb ("add X"); detail holds
        key decisions and file pointers; acceptance is testable in one
        sentence. Never invent requirements that are not in the source.
      PROMPT

      # /build <mission> step verifier — fail-closed QA gate.
      MISSION_VERIFY_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a strict QA verifier for one build step of a mission.
        You receive the todo, its acceptance criteria, and the execution
        outcome. Respond with STRICT JSON only:
          {"verdict": "pass" | "fail", "reason": "one sentence of evidence"}
        Judge ONLY on the stated evidence. If the evidence is missing,
        ambiguous, or the outcome reports errors, verdict is "fail".
      PROMPT
    end
  end
end
