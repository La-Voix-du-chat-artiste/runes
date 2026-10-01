# frozen_string_literal: true

require_relative '../compat'

module Runes
  module Security
    # ONE command-text policy checker, shared by the dispatcher
    # (`Dispatcher#run_in_workspace`) and `bin/runes-mcp` (S5-2 / E5-11).
    #
    # Token scanning is NOT confinement: an interpreter (`ruby -e`,
    # `sh -c`, `python -c`, …) can read and write anywhere the process can,
    # so no amount of path-token inspection bounds it. The policy is
    # therefore deny-by-default:
    #
    #   1. shell metacharacters (separators, substitutions, redirects) are
    #      refused outright — only fd-to-fd redirects (`2>&1`) pass;
    #   2. any path-looking token that leaves the workspace is refused;
    #   3. the command that will actually execute must be on an allowlist
    #      (the small non-interpreter DEFAULT_ALLOWLIST when
    #      RUNES_CMD_ALLOWLIST is unset), and may never be a path
    #      (`./script.sh` reopens the write-file-then-execute bypass);
    #   4. interpreters and privileged launchers are refused unless the
    #      operator names them explicitly in RUNES_CMD_ALLOWLIST.
    #
    # `RUNES_CMD_ALLOWLIST="*"` means "any command except interpreters and
    # privileged launchers"; naming an interpreter explicitly (e.g.
    # `RUNES_CMD_ALLOWLIST=ruby`) is the documented, deliberate escape
    # hatch and reopens that bypass.
    module CommandPolicy
      # Characters that let one string smuggle multiple commands or
      # substitutions: separators, substitutions, redirections, NUL.
      SHELL_METACHARACTERS = /[;&|`<>\r\n\0$]/.freeze
      # `2>&1` / `1>&2` carry no filesystem effect and are the only
      # redirects exempted from the metacharacter block.
      FD_TO_FD_REDIRECT = /\s[12]>&[12]\b/.freeze

      DANGEROUS_COMMAND_PATTERNS = [
        /\brm\s+-rf?\s+\/(?:\s|$)/,
        /\bsudo\b/,
        /\bmkfs\b/,
        /\bdd\s+if=/,
        /\bshutdown\b/,
        /\breboot\b/,
        /\/etc\/(?:passwd|shadow|sudoers)/
      ].freeze

      # Interpreters and dynamic-language runtimes. A first (or
      # launcher-reached) token that resolves to one of these is refused
      # unless it is explicitly named in RUNES_CMD_ALLOWLIST: the payload
      # after `-e` is opaque to token scanning.
      INTERPRETERS = %w[
        ruby irb rdoc ri rake bundle bundler gem
        sh bash zsh ksh dash fish csh tcsh ash
        python python2 python3 pypy pypy3
        perl php node nodejs deno bun
        lua luajit tclsh wish
        awk gawk mawk nawk sed
        groovy jruby scala kotlin
        Rscript
      ].freeze
      # Allow version suffixes without listing every one (`ruby3.2`,
      # `python3.12`); keep the un-suffixed names above for docs/tests.
      # Names are plain alphanumeric tokens, so a literal alternation is
      # exact — no Regexp.union needed (kernel subset).
      INTERPRETER_RE = /\A(?:#{INTERPRETERS.join('|')})(?:[0-9]+(?:\.[0-9]+)*)?\z/.freeze

      # Wrappers that only run what follows them. They are transparent to
      # the allowlist because the command they reach is checked too.
      TRANSPARENT_LAUNCHERS = %w[
        env nohup nice ionice stdbuf setsid timeout watch xargs flock command
      ].freeze
      # Wrappers that change privilege/root: refused outright unless
      # explicitly allowlisted.
      PRIVILEGED_LAUNCHERS = %w[sudo doas su chroot].freeze
      LAUNCHERS = (TRANSPARENT_LAUNCHERS + PRIVILEGED_LAUNCHERS).freeze
      MAX_LAUNCHER_DEPTH = 8

      # Commands that are safe to run by default: they take paths/words,
      # never another command, and cannot evaluate text. Interpreters,
      # package managers, network clients and build tools are deliberately
      # absent — operators opt into those with RUNES_CMD_ALLOWLIST.
      DEFAULT_ALLOWLIST = %w[
        ls cat echo printf pwd mkdir rmdir cp mv rm touch ln
        head tail wc grep sort uniq cut tr diff
        basename dirname realpath readlink stat file
        du df date whoami id env printenv
        sleep true false test chmod
      ].freeze

      # A command that will actually execute must be a bare name, never a
      # path: `./tool.sh` written by write_file is the classic bypass.
      COMMAND_NAME_RE = /\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z/.freeze
      # A path token may only contain these characters; anything else
      # (`File.write("/x","y")`, quotes, parens, commas, …) is not a path
      # we can confine and is treated as a violation (S5-2d). `:` is kept
      # so URLs (`echo https://…`) are not false positives.
      PATH_TOKEN_RE = %r{\A[A-Za-z0-9._/+*?@%:=-]+\z}.freeze

      # Result of a policy evaluation.
      #   category: :empty | :metacharacters | :path | :dangerous | :allowlist
      # Plain class (no keyword_init Struct) to stay inside the kernel subset.
      class Verdict
        attr_accessor :category, :message, :token

        def initialize(category, message, token = nil)
          @category = category
          @message = message
          @token = token
        end
      end

      class << self
        # Evaluate `cmd` and return nil when it is allowed, or a Verdict
        # naming the first rule it violates.
        #
        # @param allowlist [Array<String>, nil] parsed RUNES_CMD_ALLOWLIST
        # @param path_resolver [#call] -> absolute path, or nil when the
        #   token escapes the workspace
        def evaluate(cmd, allowlist: nil, path_resolver:)
          command = cmd.to_s
          redirect_scan = command.gsub(FD_TO_FD_REDIRECT, ' ')
          if redirect_scan.match?(SHELL_METACHARACTERS)
            return verdict(:metacharacters, 'Error: shell metacharacters not allowed')
          end

          if (token = path_violation(redirect_scan, path_resolver))
            return verdict(:path, "Error: path escapes the workspace (#{token[0, 60]})", token)
          end

          if dangerous?(command)
            return verdict(:dangerous, 'Error: command blocked by policy')
          end

          tokens = command_position_tokens(command)
          return verdict(:empty, 'Error: invalid args') if tokens.empty?

          if (message = refusal_for(tokens, allowlist))
            return verdict(:allowlist, message, tokens.last)
          end

          nil
        end

        # True when the command matches a hard destructive pattern (the
        # same list used by both callers).
        def dangerous?(cmd)
          DANGEROUS_COMMAND_PATTERNS.any? { |pattern| cmd.to_s.match?(pattern) }
        end

        # Parse a RUNES_CMD_ALLOWLIST value. nil means "no explicit list"
        # (the default allowlist applies); [] means "nothing allowed".
        def parse_allowlist(raw)
          return nil if raw.nil?

          text = raw.to_s.strip
          return nil if text.empty?

          text.split(',').map { |v| v.strip }.reject { |v| v.empty? }
        end

        # True when `cmd`'s executable token(s) pass the allowlist and
        # interpreter policy (path containment is evaluated separately).
        def allowlisted?(cmd, allowlist: nil)
          tokens = command_position_tokens(cmd.to_s)
          return false if tokens.empty?

          refusal_for(tokens, allowlist).nil?
        end

        # The workspace-escaping token in `cmd`, or nil. Tokens are
        # examined whole; `-o/tmp/x` and `--out=/tmp/x` are split into
        # their attached value first (S5-2c).
        def path_violation(cmd, path_resolver)
          cmd.to_s.split(/\s+/).each do |raw|
            token = raw.to_s
            next if token.empty?

            if token.start_with?('-')
              _name, attached = split_option(token)
              next if attached.nil? || attached.empty?

              token = attached
            end

            token = token.sub(/\A["']/, '').sub(/["']\z/, '')
            next if token.empty?

            return token if token.start_with?('~')
            return token if token.start_with?('/')
            return token if token.split('/').include?('..')

            next unless token.include?('/') || token.start_with?('.')

            # Not a plain path (embedded quotes/parens/commas/…): we cannot
            # classify it, so fail closed instead of calling it a relative
            # filename (S5-2d).
            return token unless token.match?(PATH_TOKEN_RE)

            return token if path_resolver.call(token).nil?
          end
          nil
        rescue StandardError => e
          warn "[CommandPolicy] path check failed (#{e.class}: #{e.message}) — failing closed"
          cmd.to_s
        end

        # The executable tokens of `cmd`, following transparent launchers:
        # `timeout 5 ruby -e x` -> ['timeout', 'ruby']; `nice -n 5 ls` ->
        # ['nice', 'ls']. Returns at most MAX_LAUNCHER_DEPTH entries.
        def command_position_tokens(cmd)
          tokens = cmd.to_s.split(/\s+/).reject { |v| v.empty? }
          out = []
          i = 0
          while i < tokens.length && out.length <= MAX_LAUNCHER_DEPTH
            token = tokens[i]
            if option_like?(token) || assignment_like?(token) || numeric_operand?(token)
              i += 1
              next
            end

            out << token
            break unless launcher?(basename(token))

            i += 1
          end
          out
        end

        def interpreter?(name)
          INTERPRETER_RE.match?(basename(name).to_s)
        end

        def launcher?(name)
          LAUNCHERS.include?(basename(name).to_s)
        end

        private

        def verdict(category, message, token = nil)
          Verdict.new(category, message, token)
        end

        # The refusal message for the command-position tokens, or nil when
        # every one of them is permitted.
        def refusal_for(tokens, allowlist)
          actual = tokens.last
          tokens.each do |token|
            name = basename(token)
            explicit = explicit_allow?(name, allowlist)

            if PRIVILEGED_LAUNCHERS.include?(name) && !explicit
              return "Error: command not on RUNES_CMD_ALLOWLIST (privileged '#{name}' must be listed explicitly)"
            end
            if interpreter?(name) && !explicit
              return "Error: command not on RUNES_CMD_ALLOWLIST (interpreter '#{name}' must be listed explicitly)"
            end
            next if TRANSPARENT_LAUNCHERS.include?(name)
            next if allowed_name?(name, allowlist)

            return "Error: command not on RUNES_CMD_ALLOWLIST (#{name.inspect})"
          end

          unless actual.to_s.match?(COMMAND_NAME_RE)
            return "Error: command paths are not allowed (#{actual.to_s[0, 60]})"
          end

          nil
        end

        def allowed_name?(name, allowlist)
          return DEFAULT_ALLOWLIST.include?(name) if allowlist.nil?

          allowlist.include?(name) || allowlist.include?('*')
        end

        def explicit_allow?(name, allowlist)
          !allowlist.nil? && allowlist.include?(name)
        end

        def basename(token)
          Compat.basename(token)
        rescue ArgumentError
          token.to_s
        end

        def option_like?(token)
          token.start_with?('-') && token.length > 1
        end

        def assignment_like?(token)
          token.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
        end

        # Launcher operands that are not commands: `timeout 5 …`,
        # `nice 10 …`, `watch -n 2 …` (the option form is skipped as an
        # option; bare numbers appear here).
        def numeric_operand?(token)
          token.match?(/\A\d+(?:\.\d+)?[smhd]?\z/)
        end

        # Split an option token into [name, attached_value]:
        #   -o/tmp/x    -> ['o', '/tmp/x']
        #   --out=/tmp/x -> ['out', '/tmp/x']
        #   -rf          -> ['rf', nil]
        def split_option(token)
          body = token.to_s.sub(/\A-+/, '')
          return [body, nil] if body.empty?

          if (index = body.index('='))
            [body[0...index], body[(index + 1)..]]
          elsif (index = body.index('/'))
            [body[0...index], body[index..]]
          else
            [body, nil]
          end
        end
      end
    end
  end
end
