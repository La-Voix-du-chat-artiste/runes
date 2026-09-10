# frozen_string_literal: true

require "pathname"
require "erb"

require_relative "util"
require_relative "errors"

module Runes
  # Parameters passed to a workflow: positional targets, bare symbol flags and
  # key=value keyword arguments. Mirrors `Roast::WorkflowParams`.
  class WorkflowParams
    attr_reader :targets, :args, :kwargs

    def initialize(targets = [], args = [], kwargs = {})
      @targets = Array(targets).map(&:to_s)
      @args = Array(args).map { |value| value.is_a?(Symbol) ? value : value.to_s.to_sym }
      @kwargs = (kwargs || {}).each_with_object({}) do |(key, value), hash|
        hash[key.to_s.to_sym] = value
      end
    end

    # Accepts an existing WorkflowParams, a Hash-like (`targets:`/`args:`/
    # `kwargs:`), a bare Array of targets, or nil.
    def self.from(value)
      case value
      when WorkflowParams
        value
      when Hash
        new(value[:targets] || value["targets"] || [],
            value[:args] || value["args"] || [],
            value[:kwargs] || value["kwargs"] || {})
      when nil
        new
      else
        new(Array(value))
      end
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
      @workflow_dir = Pathname.new(workflow_dir)
      @timeout = timeout
      @deadline = timeout && (monotonic + timeout.to_f)
    end

    # True once the workflow's wall-clock budget is exhausted. `timeout: nil`
    # (the default) never expires.
    def expired?
      return false if @deadline.nil?

      monotonic >= @deadline
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
      Pathname.new(workflow_context.tmpdir).realpath
    end

    # ERB template lookup, matching Roast's search order:
    # workflow dir, workflow dir/{prompts,templates}, current dir,
    # current dir/{prompts,templates}; each with "", ".erb", ".md.erb".
    def template(path, args = {})
      path = Pathname.new(path) unless path.is_a?(Pathname)
      candidates = []
      candidates << path if path.absolute?

      bases = [workflow_context.workflow_dir, Pathname.pwd]
      bases.each do |base|
        [base, base / "prompts", base / "templates"].each do |dir|
          candidates << dir / path
          candidates << Pathname.new("#{dir / path}.erb")
          candidates << Pathname.new("#{dir / path}.md.erb")
        end
      end

      begin
        expanded = Pathname.new(File.expand_path(path.to_s))
        candidates << expanded
        candidates << Pathname.new("#{expanded}.erb")
        candidates << Pathname.new("#{expanded}.md.erb")
      rescue ArgumentError
        # `~unknown_user/...` cannot be expanded; the other candidates stand.
      end

      resolved = candidates.find(&:exist?)
      unless resolved
        raise Runes::CogInputContext::ContextNotFoundError, "The file '#{path}' could not be found"
      end

      ERB.new(resolved.read).result_with_hash(args)
    end
  end
end
