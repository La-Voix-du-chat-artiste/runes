# frozen_string_literal: true

module Runes
  # Runtime capability seam: what the current runtime can do.
  #
  # CRuby (wired by lib/runes/backends/cruby.rb): dynamic bindings on
  # (third-party `use` runes, `Config.field`, method_missing delegation,
  # ERB templates) and `require_cog` performs real requires.
  #
  # A compiled Spinel kernel (the spin entries): dynamic bindings OFF —
  # the engine uses its literal static bindings for the seven builtin
  # verbs and raises a clear error for anything else; `require_cog`
  # raises because `use` cannot load code in a compiled binary.
  module Runtime
    class StaticBindingError < StandardError; end

    @dynamic_bindings = false

    def self.dynamic_bindings?
      @dynamic_bindings
    end

    def self.dynamic_bindings=(value)
      @dynamic_bindings = (value == true)
    end

    # Loading a `use`d cog at runtime. Overridden on CRuby; a compiled
    # kernel has every plugin compiled in and cannot load more.
    def self.require_cog(_path)
      raise LoadError, 'use/from: is only available on CRuby (a compiled kernel has its plugins built in)'
    end

    # Resolves a `use`d loadable name to a rune class. Overridden on CRuby
    # (the lookup needs const_get, which a compiled kernel refuses).
    def self.resolve_rune_class(_loadable)
      raise NameError, 'use is only available on CRuby (a compiled kernel has its plugins built in)'
    end

    # Dynamic output-accessor binding for third-party rune types
    # (CogInputContext#bind_rune_type). Overridden on CRuby; a compiled
    # kernel has literal builtin trios and raises here.
    def self.bind_rune_type(_context, method_name)
      raise StaticBindingError,
            "rune type #{method_name.inspect} has no static binding in this runtime; " \
            'compiled kernels support the seven builtin verbs'
    end

    # Dynamic config-verb binding (ConfigManager#bind_rune). Overridden on
    # CRuby; a compiled kernel configures the builtin verbs through literal
    # bindings and raises here for anything else.
    def self.bind_config_verb(_context, method_name, _on_config, _rune_class)
      raise StaticBindingError,
            "config for rune #{method_name.inspect} has no static binding in this runtime; " \
            'compiled kernels configure the seven builtin verbs'
    end

    # Dynamic execute-verb binding (ExecutionManager#bind_rune). Overridden
    # on CRuby; a compiled kernel executes the builtin verbs through literal
    # bindings and raises here for anything else.
    def self.bind_rune_verb(_context, method_name, _on_execute, _rune_class)
      raise StaticBindingError,
            "rune #{method_name.inspect} has no static binding in this runtime; " \
            'compiled kernels support the seven builtin verbs (third-party `use` is CRuby-only)'
    end

    # Evaluating a workflow source file (Workflow#extract_dsl_procs!).
    # Overridden on CRuby (instance_eval); an AOT-compiled kernel cannot
    # eval source at runtime — a compiled workflow is baked into the binary
    # at build time.
    def self.eval_workflow_source(_workflow, _source, _path)
      raise StaticBindingError,
            'evaluating workflow source files is CRuby-only; a compiled kernel has its workflows built in'
    end
  end
end
