# frozen_string_literal: true

require_relative 'core/llm_client'
require_relative 'llm/ruby_llm_adapter'

module Runes
  # Provider-adapter seam over the hand-rolled router.
  #
  # `Runes::Core::LLMClient` stays the default (behaviour unchanged); this
  # registry exists so an embedder can swap in the community `ruby_llm` gem
  # or their own router without forking the dispatcher:
  #
  #   Runes::LLM.adapter                       # -> Core::LLMClient
  #   ENV['RUNES_LLM_ADAPTER'] = 'ruby_llm'    # -> LLM::RubyLLMAdapter
  #   Runes::LLM.register(:mine, MyAdapter)
  #   ENV['RUNES_LLM_ADAPTER'] = 'mine'        # -> MyAdapter
  #
  # Selection is read at call time (not memoized), so tests and embedders can
  # flip adapters without restarting the process.
  module LLM
    # Raised when the selected adapter is unknown or its backing gem is
    # missing. The message is meant to be shown to an operator as-is.
    class AdapterUnavailable < StandardError; end

    ENV_VAR = 'RUNES_LLM_ADAPTER'
    DEFAULT = 'builtin'

    # Friendly spellings -> registry key. Kept tiny on purpose; the registry
    # itself is the source of truth for pluggable names.
    ALIASES = {
      ''         => DEFAULT,
      'default'  => DEFAULT,
      'builtin'  => DEFAULT,
      'runes'    => DEFAULT,
      'ruby_llm' => 'ruby_llm',
      'rubyllm'  => 'ruby_llm',
      'ruby-llm' => 'ruby_llm'
    }.freeze

    @registry = {}
    @mutex = Mutex.new

    class << self
      # Plug in an embedder's adapter. `builder` is either a class whose
      # initializer takes a settings object (anything exposing #env/#get,
      # e.g. Runes::Core::Settings) or a callable receiving that settings
      # object. Passing a class that also defines `.available?` -> false
      # makes selection fail with AdapterUnavailable instead of a LoadError.
      def register(name, builder = nil, &block)
        builder ||= block
        raise ArgumentError, 'register(name, klass) needs a class or a block' if builder.nil?

        @mutex.synchronize { @registry[normalize(name)] = builder }
        builder
      end

      # Snapshot of registered names -> builders (for diagnostics/tests).
      def registered
        @mutex.synchronize { @registry.dup }
      end

      # Build the adapter for `name:` (or RUNES_LLM_ADAPTER, or the built-in
      # router when neither is set).
      def adapter(settings = nil, name: nil)
        key = normalize(name || ENV[ENV_VAR])
        key = DEFAULT if key.empty?

        builder = @mutex.synchronize { @registry[key] }
        raise AdapterUnavailable, unknown_message(key) if builder.nil?

        ensure_available!(key, builder)
        instantiate(builder, settings)
      end

      private

      def normalize(name)
        ALIASES.fetch(name.to_s.strip.downcase, name.to_s.strip.downcase)
      end

      # A builder advertises its backing gem via `.available?`; the built-in
      # adapter has no such check because its deps are hard runtime deps.
      def ensure_available!(key, builder)
        return unless builder.respond_to?(:available?)
        return if builder.available?

        raise AdapterUnavailable, unavailable_message(key, builder)
      end

      def instantiate(builder, settings)
        return builder.new(settings) if builder.is_a?(Class)
        return builder.call(settings) if builder.respond_to?(:call)

        raise AdapterUnavailable, "#{builder.inspect} is not a usable LLM adapter (need a class or callable)"
      end

      # Name both the gem and the env var: the two things an operator needs
      # to fix the failure.
      def unavailable_message(key, builder)
        gem = builder.respond_to?(:gem_name) ? builder.gem_name : key
        "#{ENV_VAR}=#{key} needs the '#{gem}' gem, which is not installed. " \
          "Install it (`gem install #{gem}`, or add `gem \"#{gem}\"` to your Gemfile), " \
          "or unset #{ENV_VAR} to keep the built-in router."
      end

      def unknown_message(key)
        known = registered.keys.sort.join(', ')
        "unknown LLM adapter '#{key}' (#{ENV_VAR}=#{key}); registered adapters: #{known}"
      end
    end

    # Built-in default — unchanged behaviour from before the seam existed.
    register(DEFAULT, Runes::Core::LLMClient)
    # Lazy: the adapter class only requires 'ruby_llm' inside its methods.
    register('ruby_llm', RubyLLMAdapter)
  end
end
