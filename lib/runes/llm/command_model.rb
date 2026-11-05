# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'timeout'

require_relative '../compat'

module Runes
  module LLM
    # Run any stdin→stdout model command without a shell.
    #
    # The command is an Array (or a String split with Shellwords); model
    # output is never interpolated into a shell. A timeout, a missing binary
    # and a non-zero exit are structured failures, not exceptions.
    class CommandModel
      attr_reader :command, :timeout_s, :model_name

      def initialize(command:, timeout_s: 300, cleaner: nil, model_name: nil, runner: nil)
        @command = normalize_command(command)
        @timeout_s = timeout_s.to_f
        @cleaner = cleaner
        @model_name = model_name || File.basename(@command.first.to_s)
        @runner = runner || method(:capture)
      end

      def call(prompt, role: nil, max_tokens: nil)
        started = Runes::Compat.monotonic
        stdout, stderr, status = Timeout.timeout(@timeout_s) do
          @runner.call(@command, prompt.to_s)
        end
        elapsed = Runes::Compat.monotonic - started

        unless status.respond_to?(:success?) && status.success?
          code = status.respond_to?(:exitstatus) ? status.exitstatus : 'unknown'
          return failure(:infra, "model command exited #{code}: #{tail(stderr)}", elapsed)
        end

        content = @cleaner ? @cleaner.call(stdout.to_s) : clean(stdout.to_s)
        if content.strip.empty?
          return failure(:empty_stop, "model command produced empty stdout#{stderr_tail(stderr)}", elapsed)
        end

        {
          ok: true,
          content: content,
          usage: nil,
          finish_reason: nil,
          status: :ok,
          error: nil,
          elapsed_s: elapsed,
          raw: stdout.to_s
        }
      rescue Timeout::Error
        failure(:infra, "model command timed out after #{@timeout_s}s", Runes::Compat.monotonic - started)
      rescue Errno::ENOENT => e
        failure(:infra, "model command not found: #{e.message}", Runes::Compat.monotonic - started)
      rescue StandardError => e
        failure(:error, "#{e.class}: #{e.message}", Runes::Compat.monotonic - started)
      end

      def available?
        executable = @command.first.to_s
        return false if executable.empty?

        return File.file?(executable) && File.executable?(executable) if executable.include?('/')

        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, executable)
          File.file?(path) && File.executable?(path)
        end
      end

      def availability_error
        return nil if available?

        "model command not executable: #{@command.first.inspect}"
      end

      private

      def capture(argv, stdin)
        Open3.capture3(*argv, stdin_data: stdin)
      end

      def normalize_command(command)
        values =
          if command.is_a?(Array)
            command
          else
            Shellwords.split(command.to_s)
          end
        raise ArgumentError, 'command must not be empty' if values.empty?

        values.map(&:to_s)
      end

      def clean(text)
        text.gsub(/\e\[[0-9;]*m/, '').strip
      end

      def tail(text)
        text.to_s.lines.last(5).join.strip
      end

      def stderr_tail(stderr)
        text = tail(stderr)
        text.empty? ? '' : " (stderr: #{text})"
      end

      def failure(status, message, elapsed)
        {
          ok: false,
          content: nil,
          usage: nil,
          finish_reason: nil,
          status: status,
          error: message,
          elapsed_s: elapsed
        }
      end
    end
  end
end
