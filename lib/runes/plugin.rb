# frozen_string_literal: true

module Runes
  # A plugin is a named capability the harness can load — the same idea as a
  # DSH plugin, applied to Runes.
  #
  # Every Roast "cog" is re-implemented here as a `:rune` plugin, so the
  # workflow DSL is assembled from plugins (Chat, Agent, Ruby, Cmd, Map,
  # Repeat, Call) rather than hard-coded verbs. Registering another plugin
  # with `kind: :rune` makes it available inside workflows with no change to
  # the DSL (on CRuby; a compiled kernel binds the builtin verbs statically —
  # see Runes::Runtime).
  #
  #   class Runes::Plugins::Greet < Runes::Plugin
  #     plugin :greet, description: "Say hello"
  #     def execute(name) = "hello #{name}"
  #   end
  #
  #   Runes::Plugin[:greet]            # => Runes::Plugins::Greet
  #   Runes::Plugin.all(kind: :rune)   # => [Chat, Agent, Ruby, Cmd, ...]
  class Plugin
    class Error < StandardError; end
    class DefinitionError < Error; end
    class UnknownPlugin < Error; end

    # Plain class (no keyword_init Struct) to stay inside the kernel subset.
    class Definition
      attr_reader :name, :kind, :description, :klass

      def initialize(name:, kind:, description:, klass:)
        @name = name
        @kind = kind
        @description = description
        @klass = klass
      end

      def key
        [kind, name]
      end

      def to_s
        "#{kind}:#{name}"
      end
    end

    class << self
      # --- registry -----------------------------------------------------

      def registry
        @registry ||= {}
      end

      def register(klass, name:, kind: :rune, description: nil, replace: false)
        name = name.to_sym
        key = [kind.to_sym, name]
        if registry.key?(key) && !replace && registry[key].klass != klass
          raise DefinitionError,
                "plugin #{kind}:#{name} is already registered by #{registry[key].klass}"
        end

        definition = Definition.new(name: name, kind: kind.to_sym, description: description, klass: klass)
        definitions.reject! { |d| d.key == definition.key } # a re-registration never leaves a stale entry
        registry[definition.key] = definition
        definitions << definition unless definitions.include?(definition)
        definition
      end

      # Look up by name; raises rather than returning nil so a typo in a
      # workflow fails loudly.
      def fetch(name, kind: :rune)
        registry[[kind.to_sym, name.to_sym]] ||
          raise(UnknownPlugin,
                "no #{kind} plugin named #{name.inspect} (known: #{names(kind: kind).join(', ')})")
      end

      def [](name, kind: :rune)
        registry[[kind.to_sym, name.to_sym]]&.klass
      end

      def registered?(name, kind: :rune)
        registry.key?([kind.to_sym, name.to_sym])
      end

      def all(kind: :rune)
        definitions.select { |d| kind.nil? || d.kind == kind.to_sym }
      end

      def names(kind: :rune)
        all(kind: kind).map { |v| v.name }.sort
      end

      def definitions
        @definitions ||= []
      end

      # Classes that have called `plugin` at least once. A declaration is
      # permanent — `reset!` forgets ad-hoc registrations, not declarations,
      # so the built-in plugins are never lost to a cleanup call.
      def declared
        @declared ||= []
      end

      # Tests and embedders: forget runtime registrations and re-declare the
      # built-ins. Never leaves the harness without its runes.
      #
      # A declaration is only recorded after `register` succeeds, and the
      # rebuild uses `replace: true`, so a shadowed name cannot make a later
      # `reset!` raise and leave the registry half-built (X5-3). Any class
      # that still fails to re-register is collected and returned instead of
      # aborting the loop.
      def reset!
        @registry = {}
        @definitions = []
        failures = []
        declared.each do |klass|
          begin
            register(klass, name: klass.plugin_name, kind: klass.plugin_kind,
                            description: klass.plugin_description, replace: true)
          rescue Error => e
            failures << [klass, e]
          end
        end
        failures
      end

      # --- declaration ---------------------------------------------------

      # Declares this class as a plugin. Called once per plugin class. The
      # class is recorded in `declared` only once the registration succeeded:
      # a failed `plugin` call (a name collision without `replace: true`) must
      # not poison every later `reset!` (X5-3).
      def plugin(name = nil, kind: :rune, description: nil, replace: false)
        declared_name = (name || default_plugin_name).to_sym
        if declared_name.to_s.empty?
          raise DefinitionError, "#{self} must be given an explicit plugin name (anonymous class?)"
        end

        @plugin_name = declared_name
        @plugin_kind = kind.to_sym
        @plugin_description = description
        Plugin.register(self, name: @plugin_name, kind: @plugin_kind,
                              description: description, replace: replace)
        Plugin.declared << self unless Plugin.declared.include?(self)
        self
      end

      attr_reader :plugin_description

      def plugin_name
        @plugin_name || default_plugin_name
      end

      def plugin_kind
        @plugin_kind || :plain
      end

      def plugin_definition
        registry[[plugin_kind, plugin_name]]
      end

      def default_plugin_name
        name.to_s.split("::").last
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
            .to_sym
      end
    end

    # --- instances --------------------------------------------------------

    def initialize(context: nil, **options)
      @context = context
      @options = options
    end

    attr_reader :context, :options

    def plugin_name
      self.class.plugin_name
    end

    def plugin_kind
      self.class.plugin_kind
    end

    def describe
      "#{plugin_kind}:#{plugin_name}"
    end

    # Plugins override this. `context` is whatever the caller passed in
    # (for the workflow DSL it is the workflow run context).
    def execute(*)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end
  end
end
