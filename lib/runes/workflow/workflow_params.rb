# frozen_string_literal: true

require_relative "util"
require_relative "errors"
require_relative "../compat"

module Runes
  # Parameters passed to a workflow: positional targets, bare symbol flags and
  # key=value keyword arguments. Mirrors `Roast::WorkflowParams`.
  class WorkflowParams
    attr_reader :targets, :args, :kwargs

    def initialize(targets = [], args = [], kwargs = {})
      target_arr = targets.is_a?(Array) ? targets : [targets]
      @targets = []
      target_arr.each { |value| @targets << value.to_s }
      arg_arr = args.is_a?(Array) ? args : [args]
      @args = []
      arg_arr.each do |value|
        @args << (value.is_a?(Symbol) ? value : value.to_s.to_sym)
      end
      @kwargs = {}
      (kwargs || {}).each do |key, value|
        @kwargs[key.to_s.to_sym] = value
      end
    end

    # Accepts an existing WorkflowParams, a Hash-like (`targets:`/`args:`/
    # `kwargs:`), a bare Array of targets, or nil. The hash/array arms go
    # through helpers so the analyzer sees a Hash-typed (resp. Array-typed)
    # parameter at the lookup sites.
    def self.from(value)
      return value if value.is_a?(WorkflowParams)
      return new if value.nil?
      return from_hash(value) if value.is_a?(Hash)
      return new(value) if value.is_a?(Array)

      new([value])
    end

    def self.from_hash(hash)
      targets = hash['targets']
      targets = hash[:targets] if targets.nil?
      args = hash['args']
      args = hash[:args] if args.nil?
      kwargs = hash['kwargs']
      kwargs = hash[:kwargs] if kwargs.nil?
      new(targets || [], args || [], kwargs || {})
    end

    def to_h
      { targets: targets, args: args, kwargs: kwargs }
    end

    def deep_dup
      self.class.new(targets.dup, args.dup, kwargs.dup)
    end
  end

  # Everything a rune needs about the run that is not a step argument.
  class WorkflowContext
    attr_reader :params, :tmpdir, :workflow_dir, :timeout

    def initialize(params:, tmpdir:, workflow_dir:, timeout: nil)
      @params = params
      @tmpdir = tmpdir
      @workflow_dir = File.expand_path(workflow_dir.to_s)
      @timeout = timeout
      @deadline = timeout && (Runes::Compat.monotonic + timeout.to_f)
    end

    # True once the workflow's wall-clock budget is exhausted. `timeout: nil`
    # (the default) never expires.
    def expired?
      return false if @deadline.nil?

      Runes::Compat.monotonic >= @deadline
    end
  end

  # Mixed into `Runes::CogInputContext` (for input blocks) and extended onto
  # each `Runes::Cog::Config` (for config blocks): the Roast workflow-param
  # accessors plus `tmpdir` and `template`.
  module WorkflowParamAccessors
    attr_accessor :workflow_context

    def params
      workflow_context.params
    end

    def target!
      list = params.targets
      raise ArgumentError, "expected exactly one target" unless list.length == 1

      list.first
    end

    def targets
      params.targets.dup
    end

    def arg?(value)
      params.args.include?(value)
    end

    def args
      params.args.dup
    end

    def kwarg(key)
      params.kwargs[key]
    end

    def kwarg!(key)
      raise ArgumentError, "expected keyword argument '#{key}' to be present" unless params.kwargs.include?(key)

      params.kwargs[key]
    end

    def kwarg?(key)
      params.kwargs.include?(key)
    end

    def kwargs
      params.kwargs.dup
    end

    def tmpdir
      File.realpath(workflow_context.tmpdir.to_s)
    end

    # ERB template lookup is CRuby-only (lib/runes/workflow/templates.rb):
    # it needs ERB and Pathname, which a compiled kernel does not carry.
    # Calling `template` in a compiled workflow raises NoMethodError — inline
    # the text instead.
  end
end
