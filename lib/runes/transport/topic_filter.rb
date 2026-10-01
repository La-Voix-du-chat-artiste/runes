module Runes
  module Transport
    # MQTT-style topic matching: ONE implementation, used by the in-process
    # hub, the MQTT adapters, the embedded broker and the capability guard.
    #
    # There used to be three (this, the broker's copy, and the guard's own
    # regex compiler) and they disagreed with each other and with the spec on
    # mid-filter `#`, trailing empty levels and `$`-prefixed topics (doc5.md
    # X5-4 / T5-7).
    #
    #   +   matches exactly one level (including an empty one)
    #   #   matches the remainder, valid ONLY as the final level
    #   `$share/<group>/<filter>` is stripped here, so callers may pass
    #   either form; the group name is validated (T5-8).
    #
    # NOTE (spinel): methods are `def self.` rather than module_function —
    # the kernel subset exposes singleton methods only (docs/spinel/spec-tier-a.md).
    module TopicFilter
      # A shared-group name is one topic level: a '/' inside it would
      # silently rewrite the filter into a different subscription (T5-8), so
      # it is rejected loudly rather than going quietly deaf.
      SHARE_GROUP_RE = /\A[^\/+#\u0000]+\z/.freeze

      def self.shared?(filter)
        filter.to_s.start_with?("$share/")
      end

      # "$share/g/a/+/b" -> ["g", "a/+/b"]; anything else -> [nil, filter]
      def self.split_shared(filter)
        text = filter.to_s
        parts = text.split("/", 3)
        return [nil, text] unless parts[0] == "$share" && parts.size == 3

        group = parts[1].to_s
        return [nil, text] unless group.match?(SHARE_GROUP_RE)

        [group, parts[2]]
      end

      def self.shared_filter(group, filter)
        group = group.to_s
        unless group.match?(SHARE_GROUP_RE)
          raise ArgumentError,
                "invalid shared-subscription group #{group.inspect} " \
                "(must be one topic level: no '/', '+', '#' or NUL)"
        end

        "$share/#{group}/#{filter}"
      end

      # `#` is a wildcard only as the final level; a filter that uses it
      # anywhere else is malformed and must be rejected (MQTT 3.1.1
      # §4.7.1.2) rather than matched as a literal or as a wildcard.
      def self.valid_filter?(filter)
        filter = filter.to_s
        return false if filter.empty?

        levels = filter.split("/", -1)
        levels.each_with_index.none? { |level, i| level == "#" && i != levels.length - 1 }
      end

      # True when `topic` matches `filter` (wildcards allowed in filter).
      def self.match?(filter, topic)
        topic = topic.to_s
        _group, filter = split_shared(filter)
        filter = filter.to_s
        return false if filter.empty? || topic.empty?
        return false unless valid_filter?(filter)

        f_levels = filter.split("/", -1)

        # MQTT 3.1.1 §4.7.2: a filter whose first level is a wildcard must
        # not match a topic whose first level starts with '$'. `$a2a/...` and
        # `$SYS/...` live in that space, so `#` must not sweep them up — on a
        # real broker it never did, which is how in-process and live
        # behaviour diverged (T5-7).
        return false if topic.start_with?("$") && ["+", "#"].include?(f_levels.first)

        t_levels = topic.split("/", -1)
        f_levels.each_with_index do |level, i|
          return true if level == "#"
          return false if i >= t_levels.length
          next if level == "+"
          return false unless level == t_levels[i]
        end

        t_levels.length == f_levels.length
      end

      # A concrete topic must not contain wildcards (MQTT 3.1.1 §4.7).
      def self.valid_topic?(topic)
        topic = topic.to_s
        !topic.empty? && !topic.include?("+") && !topic.include?("#") && !topic.include?("\u0000")
      end
    end
  end
end
