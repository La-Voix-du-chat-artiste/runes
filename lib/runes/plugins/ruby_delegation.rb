# frozen_string_literal: true

# CRuby-only extension: the `ruby` rune output's method_missing delegation
# (docs/spinel/spec-tier-c.md §C3). Loaded by lib/runes/backends/cruby.rb.
# A compiled kernel keeps `value`/`[]`/`call`/`raw_text` and reaches the
# wrapped value explicitly.
class Runes::Plugins::Ruby::Output
  def method_missing(name, *args, **kwargs, &blk)
    return value.public_send(name, *args, **kwargs, &blk) if value.respond_to?(name, false)
    return super unless value.is_a?(Hash) && value.key?(name)

    stored = value[name]
    if stored.is_a?(Proc)
      stored.call(*args, **kwargs, &blk)
    else
      stored
    end
  end

  def respond_to_missing?(name, include_private = false)
    value.respond_to?(name, false) || (value.is_a?(Hash) && value.key?(name)) || super
  end
end
