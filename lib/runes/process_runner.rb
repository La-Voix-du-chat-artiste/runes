# frozen_string_literal: true

require_relative 'process_spawner'

module Runes
  # Spawner-backed process runner for the compiled kernel's `cmd` rune —
  # the same interface as Runes::CommandRunner (which stays Open3-based on
  # CRuby). Where CommandRunner goes through Open3, this goes through
  # Runes::ProcessSpawner: no shell, exact env, pgroup kills.
  #
  #   Runes::Plugins::Cmd.command_runner = Runes::ProcessRunner::Native
  #
  # (wired by the spin kernel entries; the harness never needs it.)
  module ProcessRunner
    class Status
      def initialize(exitstatus)
        @exitstatus = exitstatus
      end

      def success?
        @exitstatus == 0
      end

      attr_reader :exitstatus
    end

    class Result
      attr_reader :out, :err, :status

      def initialize(out, err, status)
        @out = out
        @err = err
        @status = status
      end

      def success?
        !!status&.success?
      end

      def exitstatus
        status&.exitstatus
      end
    end

    module Native
      OUTPUT_CAP = 1024 * 1024

      def self.execute(command, args: [], stdin: nil, stdout_handler: nil, stderr_handler: nil,
                       timeout: nil, working_directory: nil, shell: false, stdin_content: nil)
        argv = spawn_argv(command, args, shell)
        stdin_data = stdin.nil? ? stdin_content : stdin
        spawned = Runes::ProcessSpawner.spawn(argv, env: {}, chdir: working_directory)
        out = String.new
        err = String.new

        writers = []
        writers << Thread.new do
          begin
            spawned[:stdin].write(stdin_data) if stdin_data
          rescue IOError, StandardError
            nil
          ensure
            begin
              spawned[:stdin].close
            rescue IOError
              nil
            end
          end
        end
        readers = [
          drain_stream(spawned[:stdout], out, stdout_handler),
          drain_stream(spawned[:stderr], err, stderr_handler)
        ]

        status = wait_with_timeout(spawned[:pid], timeout)
        readers.each { |v| v.join }
        writers.each { |v| v.join }

        Result.new(out, err, status)
      rescue Runes::ProcessSpawner::SpawnError => e
        Result.new('', "#{e.message}\n", Status.new(127))
      end

      def self.spawn_argv(command, args, shell)
        return ['/bin/sh', '-c', command.to_s] if shell

        if command.is_a?(Array)
          argv = command.map { |v| v.to_s }
          raise Runes::ProcessSpawner::SpawnError, 'no command provided' if argv.empty? || argv.first.empty?

          return argv
        end
        tokens = command.to_s.split(' ').reject { |v| v.empty? }
        raise Runes::ProcessSpawner::SpawnError, 'no command provided' if tokens.empty?

        tokens + args.map { |v| v.to_s }
      end

      def self.drain_stream(io, buffer, handler)
        Thread.new do
          loop do
            chunk = io.read(16_384)
            break if chunk.nil? || chunk.empty?

            buffer << chunk
            begin
              handler&.call(chunk)
            rescue StandardError
              nil
            end
            break if buffer.bytesize >= OUTPUT_CAP
          end
          io.close rescue nil
        end
      end

      def self.wait_with_timeout(pid, timeout)
        if timeout.nil?
          return normalize_status(Runes::ProcessSpawner.wait(pid))
        end

        waiter = Thread.new { Runes::ProcessSpawner.wait(pid) }
        if waiter.join(timeout)
          normalize_status(waiter.value)
        else
          Runes::ProcessSpawner.kill_tree(pid)
          normalize_status(Runes::ProcessSpawner.wait(pid))
        end
      end

      # CRuby's SIGCHLD reaper can make the raw status unavailable; a child
      # whose pipes reached EOF has exited — treat a missing status as
      # success only when we cannot know otherwise (compiled kernels always
      # know; they take the real status).
      def self.normalize_status(raw)
        return Status.new(0) if raw[:unavailable]
        return Status.new(raw[:exitstatus]) unless raw[:signaled]

        Status.new(128 + (raw[:raw] & 0x7f))
      end
    end
  end
end
