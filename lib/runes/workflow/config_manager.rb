# frozen_string_literal: true

require_relative "errors"
require_relative "util"
require_relative "workflow_params"

module Runes
  # The object the `config do ... end` blocks are evaluated against. Methods
  # are bound for `global` plus one per registered `:rune` plugin.
  class ConfigContext; end

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
      @global_config = Runes::Cog::Config.new
      @general_configs = {}
      @regexp_scoped_configs = {}
      @name_scoped_configs = {}
    end

    attr_reader :config_context, :workflow_context

    def prepare!
      raise ConfigManagerAlreadyPreparedError if preparing? || prepared?

      @preparing = true
      bind_global
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
        bind_rune(definition.name, definition.klass)
      end
    end

    def bind_rune(method_name, rune_class)
      on_config_method = method(:on_config)
      rune_method = proc do |target = nil, &config_proc|
        on_config_method.call(rune_class, target, config_proc)
      end
      raise IllegalRuneNameError, method_name if @config_context.respond_to?(method_name, true)

      @config_context.define_singleton_method(method_name, rune_method)
    end

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

    def bind_global
      on_global_method = method(:on_global)
      @config_context.define_singleton_method(:global) do |&global_proc|
        on_global_method.call(global_proc)
      end
    end

    def on_global(global_proc)
      extend_workflow_params(@global_config)
      @global_config.instance_exec(&global_proc) if global_proc
      nil
    end

    # Config objects also get the workflow-param accessors (Roast binds them
    # per object; extending is the stdlib-only equivalent).
    def extend_workflow_params(config)
      config.extend(Runes::WorkflowParamAccessors)
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
