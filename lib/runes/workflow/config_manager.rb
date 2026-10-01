# frozen_string_literal: true

require_relative "errors"
require_relative "util"
require_relative "workflow_params"

module Runes
  # The object the `config do ... end` blocks are evaluated against. The
  # verbs are DEFINED IN THE CLASS BODY (AOT compilation has no per-object
  # method tables); each delegates to this context's ConfigManager through
  # the plugin registry, keeping the class constant-free.
  class ConfigContext
    attr_accessor :__config_manager

    def global(&global_proc)
      @__config_manager.on_global(global_proc)
    end

    def cmd(target = nil, &config_proc)
      config_verb(:cmd, target, config_proc)
    end

    def ruby(target = nil, &config_proc)
      config_verb(:ruby, target, config_proc)
    end

    def chat(target = nil, &config_proc)
      config_verb(:chat, target, config_proc)
    end

    def agent(target = nil, &config_proc)
      config_verb(:agent, target, config_proc)
    end

    def call(target = nil, &config_proc)
      config_verb(:call, target, config_proc)
    end

    def map(target = nil, &config_proc)
      config_verb(:map, target, config_proc)
    end

    def repeat(target = nil, &config_proc)
      config_verb(:repeat, target, config_proc)
    end

    private

    def config_verb(verb, target, config_proc)
      klass = Runes::Plugin[verb, kind: :rune]
      if klass.nil?
        raise Runes::ConfigManager::ConfigManagerError,
              "config for rune #{verb.inspect} is not registered in this runtime"
      end

      @__config_manager.on_config(klass, target, config_proc)
    end
  end

  # Collects the workflow's config blocks, applies Roast's merge precedence
  # (global -> general -> regexp-scoped in insertion order -> name-scoped) and
  # validates the result per rune instance.
  class ConfigManager
    include Runes::WorkflowParamAccessors

    class ConfigManagerError < Runes::Error; end
    class ConfigManagerNotPreparedError < ConfigManagerError; end
    class ConfigManagerAlreadyPreparedError < ConfigManagerError; end
    class IllegalRuneNameError < ConfigManagerError; end

    def initialize(config_procs, workflow_context)
      @config_procs = config_procs
      @workflow_context = workflow_context
      @config_context = ConfigContext.new
      @config_context.__config_manager = self
      @global_config = Runes::Rune::Config.new
      @general_configs = {}
      @regexp_scoped_configs = {}
      @name_scoped_configs = {}
    end

    attr_reader :config_context, :workflow_context

    def prepare!
      raise ConfigManagerAlreadyPreparedError if preparing? || prepared?

      @preparing = true
      bind_registered_runes
      @config_procs.each { |config_proc| @config_context.instance_eval(&config_proc) }
      @prepared = true
    end

    def preparing?
      @preparing ||= false
    end

    def prepared?
      @prepared ||= false
    end

    # Returns a fresh, validated config for one rune instance.
    def config_for(rune_class, name = nil)
      raise ConfigManagerNotPreparedError unless prepared?

      config = rune_class.config_class.new(Runes.deep_dup(@global_config.values))
      config = config.merge(fetch_general_config(rune_class))
      @regexp_scoped_configs.fetch(rune_class, {}).select do |pattern, _|
        pattern.match?(name.to_s) unless name.nil?
      end.each_value { |scoped| config = config.merge(scoped) }
      config = config.merge(fetch_name_scoped_config(rune_class, name)) unless name.nil?
      config.validate!
      config
    end

    private

    def bind_registered_runes
      Runes::Plugin.all(kind: :rune).each do |definition|
        next if Runes::ExecutionManager::BUILTIN_VERBS.include?(definition.name)

        Runes::Runtime.bind_config_verb(@config_context, definition.name, method(:on_config), definition.klass)
      end
    end

    public

    # Called from ConfigContext's verb methods (a different object, so these
    # must be public).
    def on_config(rune_class, target, config_proc)
      config = case target
      when nil
        fetch_general_config(rune_class)
      when Regexp
        fetch_regexp_scoped_config(rune_class, target)
      when Symbol
        fetch_name_scoped_config(rune_class, target)
      when String
        fetch_name_scoped_config(rune_class, target.to_sym)
      else
        raise ArgumentError, "Invalid type '#{target.class}' for rune config scope"
      end

      extend_workflow_params(config)
      config.instance_exec(&config_proc) if config_proc
      nil
    end

    public

    def on_global(global_proc)
      extend_workflow_params(@global_config)
      @global_config.instance_exec(&global_proc) if global_proc
      nil
    end

    # Config objects carry the workflow-param accessors via INCLUDE in the
    # class body (`Runes::Rune::Config`): AOT compilation has no per-object
    # extend. Only `workflow_context` is set per object.
    def extend_workflow_params(config)
      config.workflow_context = @workflow_context
    end

    def fetch_general_config(rune_class)
      @general_configs[rune_class] ||= rune_class.config_class.new
    end

    def fetch_regexp_scoped_config(rune_class, pattern)
      (@regexp_scoped_configs[rune_class] ||= {})[pattern] ||= rune_class.config_class.new
    end

    def fetch_name_scoped_config(rune_class, name)
      (@name_scoped_configs[rune_class] ||= {})[name] ||= rune_class.config_class.new
    end
  end
end
