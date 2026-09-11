require 'json'
require_relative '../guard_telemetry'
require_relative '../transport/topic_filter'

module Runes
  module Capabilities
    # Capability-based access control.
    #
    # The policy maps tool identifiers to a set of allowed actions/topics.
    # Patterns support MQTT wildcards: `+` matches one level, `#` at the
    # end matches anything below. Anything else is matched literally.
    #
    # Merge order: BUILTIN_BASELINE < policy file < tool-manifest fragments.
    # Fragments are ADDITIVE-ONLY for builtin tool names (S-R2): a manifest
    # dropped into tools/ can add new actions to a builtin but can never
    # widen or replace an already-defined action — narrowing builtins is
    # the policy file's job. Override attempts warn loudly.
    #
    # NOTE (S-W2): with the shipped config (baseline grants + empty
    # policy) the Guard is effectively ALLOW-ALL for the dangerous
    # builtins; the real boundaries are `safe_path` and the command
    # denylist/allowlist. A constructor warning points operators at the
    # per-tool narrowing they should add to config/policy.json.
    class Guard
      DEFAULT_POLICY = { 'default_allow' => false, 'tools' => {} }.freeze

      # Baseline grants for the trusted host builtins so the planner path
      # is governed by the Guard without breaking out-of-the-box demos.
      # A policy file that defines the same tool/action overrides these;
      # tool-manifest fragments may only add new actions (additive-only).
      BUILTIN_BASELINE = {
        'write_file'  => { 'fs_write' => ['#'], 'fs_read' => ['#'] },
        'read_file'   => { 'fs_read' => ['#'] },
        'run_command' => { 'exec' => ['#'] }
      }.freeze

      MAX_DENY_LOG = 512

      def initialize(policy_file = nil, additional_fragments: [])
        @policy = deep_dup(DEFAULT_POLICY)
        @policy_unreadable = false
        loaded = load_policy(policy_file)

        if loaded.nil?
          # A policy that EXISTS but cannot be parsed must not silently leave
          # the builtin baseline (allow-all for write_file/read_file/
          # run_command) in force: one JSON typo used to keep write+exec
          # wide open while the warning claimed "default-deny" (S5-3).
          @policy_unreadable = true
        else
          merge_fragment!({ 'tools' => deep_dup(BUILTIN_BASELINE) })
          merge_fragment!(loaded)
          @policy['default_allow'] = !!loaded['default_allow'] if loaded.is_a?(Hash)
        end

        Array(additional_fragments).each do |f|
          merge_fragment!(f, additive_for_builtins: true)
        end
        @compiled = {}
        @deny_logged = {}
        warn_if_inert
      end

      # True when an explicitly configured policy file existed but could not
      # be read or parsed, in which case NOTHING is granted by default.
      attr_reader :policy_unreadable

      attr_reader :policy

      # Merge a tool-policy fragment into the active policy. Fragments are
      # Hashes of the form `{ 'tools' => { 'name' => { 'mqtt_publish' => [...] } } }`.
      # Malformed rules fail CLOSED (skipped with a warning) instead of
      # raising out of the constructor (W3).
      def merge_fragment!(fragment, additive_for_builtins: false)
        return unless fragment.is_a?(Hash) && fragment['tools'].is_a?(Hash)

        fragment['tools'].each do |tool, rules|
          unless rules.is_a?(Hash)
            warn "[Guard] ignoring malformed policy fragment for tool '#{tool}' (expected Hash, got #{rules.class}) — fail closed"
            next
          end
          @policy['tools'] ||= {}

          if additive_for_builtins && @policy['tools'][tool].is_a?(Hash) && !@policy['tools'][tool].empty?
            # Additive-only for already-defined (builtin) tools.
            rules.each do |action, patterns|
              if @policy['tools'][tool].key?(action)
                warn "[Guard] tool manifest tried to override builtin policy for '#{tool}'/'#{action}' — ignored (additive-only); narrow builtins via config/policy.json"
              else
                patterns = validated_patterns(tool, action, patterns)
                @policy['tools'][tool][action] = patterns if patterns
              end
            end
          else
            validated_rules(tool, rules).each do |action, patterns|
              @policy['tools'][tool] = (@policy['tools'][tool] || {}).merge(action => patterns)
            end
          end
        end
      end

      # @param report [Boolean] publish a refusal through GuardTelemetry. A
      #   caller that reports the denial itself (the workflow policy, which
      #   knows it refused a *rune*) passes false so one refusal produces one
      #   event rather than two.
      def allowed?(tool_id, action, resource, report: true)
        if tool_id.nil? || action.nil? || resource.nil?
          return deny(tool_id, action, resource, report: report)
        end

        tool_policy = tools_policy[tool_id]
        return allow_by_default? if tool_policy.nil?

        patterns = tool_policy[action_key(action)]
        # Fail closed for KNOWN tools whose action is missing or explicitly
        # revoked (S-D4): an empty/absent pattern list must never fall
        # through to default_allow.
        if patterns.nil? || patterns.empty?
          return deny(tool_id, action, resource, report: report)
        end

        return true if patterns.any? { |pattern| topic_matches?(pattern, resource) }

        deny(tool_id, action, resource, report: report)
      rescue => e
        warn "[Guard] policy error for #{tool_id}/#{action}/#{resource}: #{e.message}"
        false
      end

      private

      def deny(tool_id, action, resource, report: true)
        log_deny(tool_id, action, resource, report: report)
        false
      end

      def validated_rules(tool, rules)
        rules.each_with_object({}) do |(action, patterns), h|
          patterns = validated_patterns(tool, action, patterns)
          h[action] = patterns if patterns
        end
      end

      def validated_patterns(tool, action, patterns)
        unless patterns.is_a?(Array) && patterns.all? { |p| p.is_a?(String) }
          warn "[Guard] ignoring malformed pattern list for '#{tool}'/'#{action}' (expected Array of strings) — fail closed"
          return nil
        end
        patterns
      end

      # S-W2: surface the "guard is inert as configured" state at boot so
      # operators know the baseline grants '#' on dangerous builtins.
      def warn_if_inert
        inert = BUILTIN_BASELINE.keys.filter_map do |tool|
          rules = tools_policy[tool]
          next nil unless rules.is_a?(Hash)
          allow_all = rules.select { |_a, pats| pats.is_a?(Array) && pats.include?('#') }.keys
          "#{tool}(#{allow_all.join(',')})" unless allow_all.empty?
        end
        return if inert.empty?

        warn "[Guard] WARNING: builtin guard is allow-all for #{inert.join(', ')} — " \
             'the capability guard is inert without per-tool narrowing in config/policy.json'
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end

      # Returns the parsed policy, or nil when a configured policy exists but
      # cannot be used (fail closed). A *missing* file is not an error: it
      # means "no policy configured", which keeps the documented baseline.
      def load_policy(policy_file)
        return {} if policy_file.nil?

        JSON.parse(File.read(policy_file))
      rescue Errno::ENOENT
        warn "[Guard] no policy file at #{policy_file}; using the builtin baseline."
        {}
      rescue StandardError => e
        warn "[Guard] could not parse policy #{policy_file}: #{e.class}: #{e.message} — " \
             "refusing to fall back to the builtin baseline (fail-closed)."
        nil
      end

      def tools_policy
        @policy['tools'] || {}
      end

      def allow_by_default?
        @policy['default_allow'] == true
      end

      def action_key(action)
        case action
        when :mqtt_publish, 'mqtt_publish' then 'mqtt_publish'
        when :mqtt_subscribe, 'mqtt_subscribe' then 'mqtt_subscribe'
        when :execute, 'execute' then 'execute'
        else action.to_s
        end
      end

      # Topic matching is delegated to the ONE shared implementation
      # (doc5.md X5-4). The guard used to compile its own regex, which
      # disagreed with the broker and the in-process hub on trailing empty
      # levels and on a mid-filter '#', and one of those disagreements was
      # fail-OPEN: a policy rule "runes/prompts/" allowed publishing to the
      # different topic "runes/prompts" while denying the topic it named.
      def topic_matches?(filter, topic)
        return false if topic.to_s.empty? # '#'/'' must not match the empty topic (S-W4)
        return false unless Runes::Transport::TopicFilter.valid_filter?(filter)

        Runes::Transport::TopicFilter.match?(filter, topic)
      end

      # Structured deny logging so operators can audit guard behavior.
      # Deduplicated (bounded) — one line per distinct tool/action/resource.
      #
      # The *log line* is deduplicated because a repeated identical line is
      # noise; the telemetry event is not, because how often a refusal happens
      # is exactly what an operator wants to see (doc5.md O2.3). The event is
      # rate-capped inside GuardTelemetry instead, so a denial loop cannot
      # become a fabric flood.
      def log_deny(tool_id, action, resource, report: true)
        if report
          Runes::GuardTelemetry.record(tool: tool_id, action: action_key(action),
                                       resource: resource, phase: 'tool')
        end
        key = "#{tool_id}/#{action_key(action)}/#{resource.to_s[0, 120]}"
        return if @deny_logged.key?(key)
        return if @deny_logged.size >= MAX_DENY_LOG

        @deny_logged[key] = true
        warn "[Guard] deny #{tool_id}/#{action_key(action)} resource=#{resource.to_s[0, 120]}"
      end
    end
  end
end
