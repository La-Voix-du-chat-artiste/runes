# frozen_string_literal: true

require_relative "../rune"
require_relative "../command_runner"

module Runes
  module Plugins
    # The `cmd` rune: run an argv command (never a shell string) and capture
    # stdout/stderr/status. Fails the rune on a non-zero exit status unless
    # `no_fail_on_error!` is configured.
    class Cmd < Runes::Rune
      plugin :cmd, description: "Run a command and capture its output"

      class << self
        attr_writer :command_runner

        # Defaults to Runes::CommandRunner; tests inject a double.
        def command_runner
          @command_runner || Runes::CommandRunner
        end

        def reset_command_runner!
          @command_runner = nil
        end
      end

      class Config < Runes::Cog::Config
        def fail_on_error!
          @values[:fail_on_error] = true
        end

        def no_fail_on_error!
          @values[:fail_on_error] = false
        end

        def fail_on_error?
          @values[:fail_on_error] != false
        end

        def show_stdout!
          @values[:show_stdout] = true
        end

        def no_show_stdout!
          @values[:show_stdout] = false
        end

        def show_stdout?
          !!@values[:show_stdout]
        end

        def show_stderr!
          @values[:show_stderr] = true
        end

        def no_show_stderr!
          @values[:show_stderr] = false
        end

        def show_stderr?
          !!@values[:show_stderr]
        end

        def display!
          @values[:show_stdout] = true
          @values[:show_stderr] = true
        end

        def no_display!
          @values[:show_stdout] = false
          @values[:show_stderr] = false
        end

        def display?
          show_stdout? || show_stderr?
        end

        # Explicit opt-in to `/bin/sh` semantics for a command String
        # (pipes, redirects, `$(...)`). Off by default: a String command is
        # shell-split and run as argv (W5-1).
        def shell!
          @values[:shell] = true
        end

        def no_shell!
          @values[:shell] = false
        end

        def shell?
          !!@values[:shell]
        end

        # Kill the command after this many seconds (W5-10). nil = no timeout.
        def timeout(seconds)
          @values[:timeout] = seconds
        end

        def use_default_timeout!
          @values.delete(:timeout)
        end

        def valid_timeout
          raw = @values[:timeout]
          return nil if raw.nil?

          value = Float(raw)
          raise InvalidConfigError, "'timeout' must be positive, got #{raw.inspect}" unless value.positive?

          value
        rescue ArgumentError, TypeError
          raise InvalidConfigError, "'timeout' must be a number of seconds, got #{raw.inspect}"
        end

        def validate!
          valid_timeout
        end

        alias quiet! no_display!
      end

      class Input < Runes::Cog::Input
        attr_accessor :command, :args, :stdin

        def initialize
          super
          @args = []
        end

        def validate!
          raise InvalidInputError, "'command' is required" if Runes.blank?(command)
        end

        # String -> command; Array -> first element is the command, the rest
        # are arguments. Roast ignores any other type and then fails
        # validation with "'command' is required", which is confusing when the
        # block returned a Hash; say what was actually wrong instead.
        def coerce(input_return_value)
          case input_return_value
          when String
            self.command = input_return_value
          when Array
            values = input_return_value.map(&:to_s)
            self.command = values.shift
            self.args = values
          when Hash
            raise InvalidInputError,
                  "cmd takes a command String or an argv Array, not a Hash " \
                  "(got #{input_return_value.keys.map(&:inspect).join(', ')}); " \
                  "write `{ \"git log --oneline\" }` or `{ [\"git\", \"log\"] }`"
          end
        end
      end

      class Output < Runes::Cog::Output
        include Runes::Cog::Output::WithJson
        include Runes::Cog::Output::WithNumber
        include Runes::Cog::Output::WithText

        attr_reader :out, :err, :status

        def initialize(out, err, status)
          super()
          @out = out
          @err = err
          @status = status
        end

        def raw_text
          out
        end
      end

      protected

      def execute(input)
        config = @config
        # The guard is off unless a policy was installed; when it is on, the
        # command TEXT is what a policy matches (like the dispatcher's rules),
        # so a narrow policy is a narrow policy.
        command_line = ([input.command] + Array(input.args)).join(" ")
        Runes::WorkflowPolicy.authorize!(rune: "cmd", action: :exec, resource: command_line,
                                           hint: 'e.g. "cmd": { "exec": ["echo *"] }')
        stdout_handler = config.show_stdout? ? ->(line) { $stdout.print(line) } : nil
        stderr_handler = config.show_stderr? ? ->(line) { $stderr.print(line) } : nil

        result = self.class.command_runner.execute(
          input.command,
          args: input.args,
          stdin: input.stdin,
          stdout_handler: stdout_handler,
          stderr_handler: stderr_handler,
          working_directory: config.valid_working_directory,
          timeout: config.valid_timeout,
          shell: config.shell?
        )

        if !result.status.success? && config.fail_on_error?
          raise Runes::ControlFlow::FailCog, "Process exited with status code #{result.status.exitstatus}"
        end

        Output.new(result.out, result.err, result.status)
      end
    end
  end
end
