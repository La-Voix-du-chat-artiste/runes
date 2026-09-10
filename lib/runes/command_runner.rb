# frozen_string_literal: true

require "open3"
require "shellwords"

require_relative "workflow/errors"

module Runes
  # The canonical way to run an external command in Runes: an argv array, no
  # shell, separate stdout/stderr capture, optional line handlers and timeout.
  #
  #   result = Runes::CommandRunner.execute("git", args: ["diff", "--name-only"])
  #   result.out     # => "a.rb\nb.rb\n"
  #   result.status  # => #<Process::Status ...>
  #
  # Destructuring also works for Roast-style call sites:
  #
  #   out, err, status = Runes::CommandRunner.execute("echo", args: ["hi"])
  #
  # `command` may be a String (with `args:`) or a complete argv Array.
  #
  # W5-1: a String command is split with `Shellwords.split` and run as argv,
  # *never* handed to `/bin/sh`. A one-element argv (including a one-element
  # Array) is deliberately spawned as `[cmd, cmd]` so Ruby cannot take its
  # "single string means shell" path. A token produced by splitting a String
  # that contains a shell metacharacter is refused with `ShellSyntaxError`
  # rather than silently changing meaning without a shell. Callers who really
  # want shell semantics (Roast's pipes/redirects) opt in with `shell: true`
  # (or `Cmd::Config#shell!`).
  class CommandRunner
    class CommandRunnerError < Runes::Error; end
    class NoCommandProvidedError < CommandRunnerError; end
    class TimeoutError < CommandRunnerError; end
    class ShellSyntaxError < CommandRunnerError; end

    # Shell control operators, substitutions and globbing/escape characters.
    # A String command whose split token contains one of these is ambiguous
    # without a shell: refuse it and make the caller choose `shell: true` or
    # an argv Array (where the token is passed literally).
    SHELL_METACHARACTERS = /[|&;<>()$`\\*?\[\]\n]/

    Result = Struct.new(:out, :err, :status, keyword_init: true) do
      def success?
        !!status&.success?
      end

      def exitstatus
        status&.exitstatus
      end

      alias stdout out
      alias stderr err

      # Roast returns `[stdout, stderr, status]`; support that destructuring.
      def to_ary
        [out, err, status]
      end
    end

    class << self
      # `stdin_content:` is accepted as a Roast-compatible alias for `stdin:`.
      # `shell: true` is the explicit opt-in to `/bin/sh` semantics; the
      # default is argv execution with no shell (W5-1).
      def execute(command, args: [], stdin: nil, stdout_handler: nil, stderr_handler: nil,
                  timeout: nil, working_directory: nil, stdin_content: nil, shell: false)
        target = spawn_target(command, args, shell: shell)

        stdin_data = stdin.nil? ? stdin_content : stdin
        out = +""
        err = +""
        status = nil
        timed_out = false
        mutex = Mutex.new

        with_unbundled_env do
          Open3.popen3(*target, **spawn_options(working_directory)) do |stdin_io, stdout_io, stderr_io, wait_thread|
            pid = wait_thread.pid

            killer = start_timeout_killer(pid, timeout, wait_thread) do
              mutex.synchronize { timed_out = true }
            end

            stdin_thread = Thread.new do
              begin
                stdin_io.write(stdin_data) if stdin_data
              rescue Errno::EPIPE, IOError
                # The command exited before reading all of stdin.
              ensure
                begin
                  stdin_io.close
                rescue IOError
                  nil
                end
              end
            end

            stdout_thread = Thread.new { read_stream(stdout_io, out, stdout_handler) }
            stderr_thread = Thread.new { read_stream(stderr_io, err, stderr_handler) }
            [stdin_thread, stdout_thread, stderr_thread].each(&:join)

            status = wait_thread.value
            killer&.kill
          end
        end

        raise TimeoutError, "Command timed out after #{timeout} seconds" if timed_out

        Result.new(out: out, err: err, status: status)
      end

      private

      # Returns the exact argument list for `Open3.popen3` (which is splatted
      # by the caller), or raises for an empty/ambiguous command.
      #
      #   * `shell: true`             -> one shell string, deliberately
      #   * Array / String + args     -> argv, never shell-interpreted
      #   * a lone String             -> Shellwords.split, metacharacters refused
      def spawn_target(command, args, shell:)
        if shell
          line = build_shell_command(command, args)
          raise NoCommandProvidedError, "no command provided" if line.strip.empty?

          return [line]
        end

        argv = build_argv(command, args)
        raise NoCommandProvidedError, "no command provided" if argv.empty? || argv.first.strip.empty?

        # A one-element argv would otherwise be routed through `/bin/sh` by
        # Ruby itself. `[cmd, argv0]` is the documented argv form, so the
        # command is executed directly even with no arguments (W5-1).
        argv.length == 1 ? [argv.first, argv.first] : argv
      end

      def build_argv(command, args)
        if command.is_a?(Array)
          # An argv Array is literal: `["echo x > f"]` is a (missing)
          # executable name, not a shell line.
          command.compact.map(&:to_s)
        else
          tokens = Shellwords.split(command.to_s)
          if (bad = tokens.find { |token| token.match?(SHELL_METACHARACTERS) })
            raise ShellSyntaxError,
                  "command string #{command.inspect} contains shell metacharacter #{bad.inspect} after " \
                  "shell-splitting; pass an argv Array (e.g. [\"sh\", \"-c\", ...]) or opt in with " \
                  "`shell: true` for shell semantics"
          end
          tokens + Array(args).compact.map(&:to_s)
        end
      end

      # The explicit shell path. A String is used verbatim (it may contain
      # pipes/redirects); `args:` are appended. An Array is joined — the
      # caller asked for a shell line, so it owns the quoting.
      def build_shell_command(command, args)
        parts = if command.is_a?(Array)
          command.compact.map(&:to_s)
        else
          [command.to_s, *Array(args).compact.map(&:to_s)]
        end
        parts.join(" ")
      end

      def spawn_options(working_directory)
        options = { pgroup: true }
        options[:chdir] = working_directory.to_s if working_directory
        options
      end

      def read_stream(io, buffer, handler)
        io.each_line do |line|
          buffer << line
          begin
            handler&.call(line)
          rescue StandardError
            # A misbehaving display handler must not break command capture.
          end
        end
      rescue IOError
        nil
      end

      def start_timeout_killer(pid, timeout, wait_thread)
        return nil unless timeout

        Thread.new do
          sleep(timeout)
          if wait_thread.alive?
            yield
            kill_process(pid)
          end
        end.tap { |thread| thread.report_on_exception = false if thread.respond_to?(:report_on_exception=) }
      end

      def kill_process(pid)
        return nil if pid.nil?

        signal("TERM", pid)
        5.times do
          sleep(0.02)
          return nil unless process_running?(pid)
        end
        signal("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def signal(name, pid)
        # Negative pid targets the process group (pgroup: true above).
        Process.kill(name, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(name, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def process_running?(pid)
        Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end

      def with_unbundled_env(&block)
        if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
          Bundler.with_unbundled_env(&block)
        else
          block.call
        end
      end
    end
  end
end
