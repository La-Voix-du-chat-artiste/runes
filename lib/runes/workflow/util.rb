# frozen_string_literal: true

module Runes
  # Small stdlib-only stand-ins for the handful of ActiveSupport helpers Roast
  # relies on. They are singleton methods on Runes::Util, never monkey-patches,
  # so loading the workflow engine cannot change the behaviour of the host
  # application. (`def self.` rather than module_function — the kernel
  # subset exposes singleton methods only.)
  module Util
    # A real deep copy: Hashes and Arrays recurse, everything else is `dup`ed
    # when Ruby allows it. Objects that cannot be copied (Process::Status,
    # Thread, Mutex, ...) are returned as-is rather than raising. IO, Thread
    # and synchronisation primitives are also returned as-is: `IO#dup`
    # allocates a fresh file descriptor, so duplicating an output that holds
    # one would leak a descriptor per rune per iteration (W5-13).
    def self.deep_dup(object)
      case object
      when Hash
        copy = {}
        object.each do |key, value|
          copy[deep_dup(key)] = deep_dup(value)
        end
        copy
      when Array
        object.map { |element| deep_dup(element) }
      when String
        object.dup
      else
        return object unless duplicable?(object)

        begin
          object.dup
        rescue TypeError
          object
        end
      end
    end

    def self.duplicable?(object)
      case object
      when nil, true, false, Symbol, Numeric, Method, UnboundMethod
        false
      when IO, Thread, Mutex, ConditionVariable, Queue, SizedQueue
        false
      else
        true
      end
    end

    # Roast uses `present?`/`blank?` from ActiveSupport; these are the only
    # semantics the engine needs (nil and empty/whitespace strings are blank).
    def self.blank?(object)
      return true if object.nil?
      return object.strip.empty? if object.is_a?(String)
      return object.empty? if object.respond_to?(:empty?)

      false
    end

    def self.present?(object)
      !blank?(object)
    end

    # `nil` for blank values, the value itself otherwise (ActiveSupport's
    # `Object#presence`).
    def self.presence(object)
      present?(object) ? object : nil
    end

    # "fake_cog" / "FakeCog" / :fake_cog -> "FakeCog" (Roast uses ActiveSupport
    # `camelize` when resolving `use(:name)`).
    def self.camelize(value)
      value.to_s.split('_').map { |v| v.capitalize }.join
    end

    # "Runes::Plugins::MyRune" -> "my_rune" (used for `#type`).
    def self.underscore(value)
      value.to_s.split('::').last
             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
             .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .downcase
    end
  end

  # Ergonomic short-hands on the Runes namespace.
  def self.deep_dup(object)
    Util.deep_dup(object)
  end

  def self.blank?(object)
    Util.blank?(object)
  end

  def self.present?(object)
    Util.present?(object)
  end

  def self.presence(object)
    Util.presence(object)
  end
end
