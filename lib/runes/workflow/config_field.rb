# frozen_string_literal: true

# CRuby-only engine extensions: the dynamic conveniences a compiled kernel
# replaces with static bindings (docs/spinel/spec-tier-c.md §C3). Loaded by
# lib/runes/backends/cruby.rb; the kernel entry never requires this file.
require_relative 'cog'

class Runes::Rune
  class Config
    # Defines `key` (get with no args / set with one) and
    # `use_default_<key>!`. `validator` may coerce and raise. CRuby-only:
    # the compiled engine ships literal config methods instead.
    def self.field(key, default, &validator)
      define_method(key) do |*args|
        if args.empty?
          value = @values[key]
          value.nil? ? Runes.deep_dup(default) : value
        else
          new_value = args.first
          @values[key] = validator ? validator.call(new_value) : new_value
        end
      end

      define_method("use_default_#{key}!") do
        @values[key] = Runes.deep_dup(default)
      end
    end
  end
end
