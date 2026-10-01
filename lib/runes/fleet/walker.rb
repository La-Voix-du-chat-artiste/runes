# frozen_string_literal: true

require "prism"
require_relative "load_error"

module Runes
  module Fleet
    # The restricted-subset AST walker (spec §6): a deny-by-default Prism
    # pass over the whole fleet file that runs BEFORE anything is
    # evaluated. Anything not explicitly whitelisted — eval, defs, constant
    # reads, receiver calls, interpolation, globals, threads, control flow —
    # aborts the load with a precise line-numbered error. Enforced
    # identically in tests, in the interpreted harness, and (L3) as the
    # Spinel conformance gate for fleet files.
    #
    # The walker checks CONSTRUCTS only; semantic placement (what may
    # appear inside which block) is the builders' job (builder.rb). Both
    # must pass — defence in depth: even a builder bug cannot admit a
    # construct the walker rejected, and vice versa.
    #
    # Rule subtrees (`on ... do |e| ... end`, and the `guard:` lambda inside
    # the `on` call) run in a second, wider mode — the §6 expression
    # language: event access, comparisons/arithmetic, static match?,
    # interpolation of validated fields, if/unless, &&/||/!, and the three
    # action calls. World mode stays exactly as narrow as Phase A left it.
    class Walker
      # Declaration vocabulary of spec §4, as bare method calls. Placement
      # is enforced by the builders; the walker only proves the file uses
      # nothing else. `spawn` / `cell` / `interval` are RESERVED keywords
      # (spec §13): allowed past the walker so the builder can reject them
      # with the precise "reserved for v0.2" error instead of a generic
      # "forbidden construct".
      ALLOWED_METHODS = %w[
        fleet config description transport group
        agent model tools workspace identity concurrency
        channel route fact schedule
        spawn cell interval
      ].freeze

      # Bare calls that only exist inside rule bodies (spec §5/§6). In
      # world contexts they pass the walker and die in the builders as
      # misplaced declarations (P3).
      RULE_BARE_METHODS = %w[on next! task publish notify fact].freeze

      # The declarations that take a block in spec v0.1. `on` blocks bind
      # exactly one parameter (`|e|`); fleet/agent blocks bind none.
      BLOCK_METHODS = %w[fleet agent on].freeze

      # §6 operator set, as receiver-call names.
      OPERATORS = %i[== != < <= > >= + - * / !].freeze

      # §6 access: event fields, event[:field], and match? with a static
      # regexp literal.
      ACCESS_CALLS = %i[[] match?].freeze

      # Receiver-call names NEVER allowed in rule expressions, even though
      # their shape matches an accessor — the metaprogramming and process
      # escape hatches (§6's forbidden list, plus the project's own
      # landmines: format/pack/extend). A guard that "needs" one of these
      # is a design argument to have in the open, not in a fleet file.
      DANGEROUS_RECEIVER_CALLS = %w[
        system exec send __send__ public_send method call
        instance_eval instance_exec eval class_eval module_eval
        define_method define_singleton_method require load open fork spawn
        exit abort const_get instance_variable_get instance_variable_set
        remove_instance_variable format sprintf pack unpack tap then
        yield_self itself extend
      ].freeze

      ACCESSOR_NAME = /\A[a-z_][a-zA-Z0-9_]*[?!]?\z/.freeze

      def initialize(path)
        @path = path
        @mode = [:world]
      end

      def verify!(program)
        program.accept(self)
        true
      end

      # Deny-by-default sink: every Prism node type without an explicit
      # handler above lands here and aborts the load. (Some exec-shaped
      # nodes — XString — bypass the sink in some Prism versions, so they
      # also get explicit handlers below.)
      def visit_missing(node)
        forbidden!(node)
      end

      # Backticks / %x: process execution, always forbidden (spec §6).
      # Explicit because Prism's dispatch can reach past visit_missing for
      # these; the message stays identical.
      def visit_x_string_node(node)
        forbidden!(node)
      end

      def visit_interpolated_x_string_node(node)
        forbidden!(node)
      end

      def visit_program_node(node)
        node.statements&.accept(self)
      end

      def visit_statements_node(node)
        node.body.each { |stmt| stmt.accept(self) }
      end

      # ---- literals (leaves and their containers) ----

      def visit_integer_node(_node); end

      def visit_float_node(_node); end

      def visit_rational_node(_node); end

      def visit_imaginary_node(_node); end

      def visit_string_node(_node); end

      def visit_symbol_node(_node); end

      def visit_true_node(_node); end

      def visit_false_node(_node); end

      def visit_nil_node(_node); end

      # Static regexp literals (§6 allows them in guards; world files may
      # carry them in facts). Treated as leaves — an interpolated regexp
      # is a different node type and the deny-by-default net rejects it.
      # (Prism has spelled the node both RegexpNode and RegularExpressionNode
      # across versions — both handlers stay.)
      def visit_regexp_node(_node); end

      def visit_regular_expression_node(_node); end

      def visit_array_node(node)
        node.elements.each { |el| el.accept(self) }
      end

      # `route :a => :b, when: :x` arrives as a KeywordHashNode at the call
      # site (Prism normalises brace-less rockets); braced hash literals
      # arrive as HashNode. Both are the same whitelist.
      def visit_hash_node(node)
        node.elements.each { |el| el.accept(self) }
      end

      def visit_keyword_hash_node(node)
        node.elements.each { |el| el.accept(self) }
      end

      def visit_assoc_node(node)
        node.key.accept(self)
        node.value.accept(self)
      end

      # ---- locals (harmless; rules will widen this carefully in §5) ----

      def visit_local_variable_read_node(_node); end

      def visit_local_variable_write_node(node)
        node.value.accept(self)
      end

      # ---- the only executable shapes: declarations and rule expressions ----

      def visit_call_node(node)
        name = node.name.to_s

        if node.receiver.nil?
          unless allowed_bare_call?(name)
            raise LoadError,
                  "fleet #{@path}: unknown construct `#{name}` at line " \
                  "#{node.location.start_line} (spec §6 whitelist)"
          end
          block = node.block
          if block
            unless BLOCK_METHODS.include?(name) && block.is_a?(Prism::BlockNode)
              raise LoadError,
                    "fleet #{@path}: `#{name}` may not take a block at line " \
                    "#{node.location.start_line}"
            end
            # World-mode blocks (fleet/agent) bind no parameters; rule
            # blocks (on ...) bind exactly |e|, enforced by the parameters
            # handler — visited under rule mode along with the body.
            rule = rule_entry?(name)
            if !rule && !block.parameters.nil?
              raise LoadError,
                    "fleet #{@path}: block parameters are reserved for rules (spec §5), " \
                    "line #{block.location.start_line}"
            end

            with_rule_mode(rule) do
              block.parameters&.accept(self)
              block.body&.accept(self)
            end
          end
          with_rule_mode(rule_entry?(name)) { node.arguments&.accept(self) }
          return
        end

        # Receiver call — only inside rule expressions, and only the §6
        # access/operator vocabulary.
        unless rule_mode? && receiver_call_allowed?(name)
          raise LoadError,
                "fleet #{@path}: method calls on receivers are forbidden at line " \
                "#{node.location.start_line} (only bare declarations, spec §6)"
        end
        if node.block
          raise LoadError,
                "fleet #{@path}: calls with blocks are forbidden in rule expressions at line " \
                "#{node.location.start_line} (spec §6)"
        end

        node.receiver.accept(self)
        node.arguments&.accept(self)
      end

      def visit_arguments_node(node)
        node.arguments.each { |arg| arg.accept(self) }
      end

      # ---- rule-mode-only constructs (§5 guards/actions, §6 expressions) ----

      def visit_if_node(node)
        rule_only!(node)
        node.predicate.accept(self)
        node.statements&.accept(self)
        node.consequent&.accept(self)
      end

      def visit_unless_node(node)
        rule_only!(node)
        node.predicate.accept(self)
        node.statements&.accept(self)
        node.consequent&.accept(self)
      end

      def visit_else_node(node)
        rule_only!(node)
        node.statements&.accept(self)
      end

      def visit_and_node(node)
        rule_only!(node)
        node.left.accept(self)
        node.right.accept(self)
      end

      def visit_or_node(node)
        rule_only!(node)
        node.left.accept(self)
        node.right.accept(self)
      end

      # `guard: ->(e) { ... }` — the lambda spelling of §5.1. World mode
      # rejects it; rule mode pins the parameter list to exactly |e|.
      def visit_lambda_node(node)
        rule_only!(node)
        check_rule_params!(node)
        node.body&.accept(self)
      end

      # Rule blocks bind exactly one parameter: the event (§5.1).
      def visit_block_parameters_node(node)
        rule_only!(node)
        inner = node.parameters
        return if inner.nil? # `do ||` — the builder requires |e| anyway

        check_params_inner!(inner, node)
      end

      # "#{e.email}" inside a task prompt: allowed in rule mode, with the
      # embedded expressions held to the same §6 whitelist.
      def visit_interpolated_string_node(node)
        rule_only!(node)
        node.parts.each { |part| part.accept(self) }
      end

      def visit_interpolated_symbol_node(node)
        rule_only!(node)
        node.parts.each { |part| part.accept(self) }
      end

      def visit_embedded_statements_node(node)
        rule_only!(node)
        node.statements&.accept(self)
      end

      private

      def rule_mode? = @mode.last == :rule

      def rule_entry?(name) = name == "on"

      def with_rule_mode(rule)
        return yield unless rule

        @mode.push(:rule)
        begin
          yield
        ensure
          @mode.pop
        end
      end

      def allowed_bare_call?(name)
        ALLOWED_METHODS.include?(name) || RULE_BARE_METHODS.include?(name)
      end

      def receiver_call_allowed?(name)
        sym = name.to_sym
        return true if OPERATORS.include?(sym) || ACCESS_CALLS.include?(sym)
        return false if DANGEROUS_RECEIVER_CALLS.include?(name)

        name.match?(ACCESSOR_NAME)
      end

      def rule_only!(node)
        return if rule_mode?

        forbidden!(node)
      end

      def check_rule_params!(node)
        params = node.parameters
        raise LoadError, "fleet #{@path}: guard lambdas must take |e| (spec §5.1), line #{node.location.start_line}" if params.nil?

        inner = params.parameters
        return if inner.nil? # `->() {}` — arity enforced by the builder at eval time

        check_params_inner!(inner, node)
      end

      # Exactly |e|: one required positional, nothing else (§5.1/§6).
      def check_params_inner!(inner, node)
        return if inner.requireds.size == 1 && inner.optionals.empty? && inner.rest.nil? &&
                  inner.posts.empty? && inner.keywords.empty? && inner.keyword_rest.nil? && inner.block.nil?

        raise LoadError,
              "fleet #{@path}: rule parameters must be exactly |e| (spec §5.1), " \
              "line #{node.location.start_line}"
      end

      # Prism's dispatch is a plain `visitor.visit_#{type}(node)` send with
      # no guaranteed fallback to visit_missing across node types and
      # versions — an unhandled node can surface as a raw NoMethodError
      # instead of reaching the deny-by-default sink. Intercept every
      # visit_* send we don't implement explicitly; respond_to_missing?
      # covers dispatch styles that probe before sending.
      def method_missing(name, *args, &)
        if name.to_s.start_with?("visit_") && (node = args.first)
          forbidden!(node)
        end

        super
      end

      def respond_to_missing?(name, include_private = false)
        name.to_s.start_with?("visit_") || super
      end

      def forbidden!(node)
        raise LoadError,
              "fleet #{@path}: forbidden construct #{node.class.name.split("::").last} " \
              "at line #{node.location.start_line} (spec FLEET_DSL.md §6 whitelist)"
      end
    end
  end
end
