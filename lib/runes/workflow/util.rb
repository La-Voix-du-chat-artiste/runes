# frozen_string_literal: true

require "pathname"
require "erb"

module Runes
  # Small stdlib-only stand-ins for the handful of ActiveSupport helpers Roast
  # relies on. They are module functions, never monkey-patches, so loading the
  # workflow engine cannot change the behaviour of the host application.
  module Util
    module_function

    # A real deep copy: Hashes and Arrays recurse, everything else is `dup`ed
    # when Ruby allows it. Objects that cannot be copied (Process::Status,
    # Thread, Mutex, ...) are returned as-is rather than raising. IO, Thread
    # and synchronisation primitives are also returned as-is: `IO#dup`
    # allocates a fresh file descriptor, so duplicating an output that holds
    # one would leak a descriptor per rune per iteration (W5-13).
    def deep_dup(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), copy|
          copy[deep_dup(key)] = deep_dup(value)
        end
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

    def duplicable?(object)
      case object
      when nil, true, false, Symbol, Numeric, Method, UnboundMethod
        false
      when IO, Thread, Mutex, Thread::Mutex, ConditionVariable, Queue, SizedQueue
        false
      else
        true
      end
    end

    # Roast uses `present?`/`blank?` from ActiveSupport; these are the only
    # semantics the engine needs (nil and empty/whitespace strings are blank).
    def blank?(object)
      return true if object.nil?
      return object.strip.empty? if object.is_a?(String)
      return object.empty? if object.respond_to?(:empty?)

      false
    end

    def present?(object)
      !blank?(object)
    end

    # `nil` for blank values, the value itself otherwise (ActiveSupport's
    # `Object#presence`).
    def presence(object)
      present?(object) ? object : nil
    end

    # "fake_cog" / "FakeCog" / :fake_cog -> "FakeCog" (Roast uses ActiveSupport
    # `camelize` when resolving `use(:name)`).
    def camelize(value)
      value.to_s.split("_").map(&:capitalize).join
    end

    # "Runes::Plugins::MyRune" -> "my_rune" (used for `#type`).
    def underscore(value)
      value.to_s.split("::").last
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .downcase
    end
  end

  # Ergonomic short-hands on the Runes namespace.
  def self.deep_dup(object) = Util.deep_dup(object)
  def self.blank?(object) = Util.blank?(object)
  def self.present?(object) = Util.present?(object)
  def self.presence(object) = Util.presence(object)
end
