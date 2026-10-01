# frozen_string_literal: true

require_relative '../compat'

module Runes
  # A unit of asynchronous work, backed by a Ruby Thread.
  #
  # This is the deliberate deviation from Roast: Roast builds on the `async`
  # gem, but Runes must not add a dependency, so `async!` runs the rune on a
  # thread and output accessors join that thread. The observable semantics —
  # "the rune runs concurrently, `X!(name)` blocks until it finishes, the
  # scope does not complete until every rune has" — are preserved; the
  # difference is that a thread already running cannot be cooperatively
  # cancelled, so `stop` only stops work that has not started yet.
  class Task
    def initialize(on_complete: nil, autostart: true, &block)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @done = false
      @stopped = false
      @value = nil
      @exception = nil
      @on_complete = on_complete
      # A task created for an already-stopped group must not run at all: the
      # block used to execute and only then be marked stopped (doc5.md W5-8),
      # so a post-stop `async` did work nobody would ever observe.
      unless autostart
        @done = true
        @stopped = true
        @thread = nil
        return
      end
      @thread = Thread.new do
        begin
          @value = block.call(self)
        rescue Exception => e # rubocop:disable Lint/RescueException -- ControlFlow is a StandardError; SystemExit must not leak from a worker
          @exception = e
        ensure
          @mutex.synchronize do
            @done = true
            @condition.broadcast
          end
          # Announce completion *after* setting @done so a waiter that pops
          # this task sees a finished task (W5-5).
          begin
            @on_complete&.call(self)
          rescue StandardError
            nil
          end
        end
      end
      @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
    end

    # Joins the thread and re-raises whatever it raised, in the caller.
    def wait
      @mutex.synchronize do
        @condition.wait(@mutex) until @done
      end
      raise @exception if @exception

      @value
    end

    # A task that never started is not "running"; used by TaskGroup#stop to
    # decide what still needs joining.
    def started?
      !@thread.nil?
    end

    def finished?
      @mutex.synchronize { @done && @exception.nil? }
    end

    def failed?
      @mutex.synchronize { @done && !@exception.nil? }
    end

    def exception
      @mutex.synchronize { @exception }
    end

    def stopped?
      @stopped
    end

    def mark_stopped!
      @stopped = true
    end

    def thread
      @thread
    end
  end

  # A thread-backed replacement for `Async::Barrier`: spawns tasks, tracks
  # them, and can stop starting new work.
  class TaskGroup
    class << self
      def current
        Thread.current[:runes_task_group]
      end

      def current=(group)
        Thread.current[:runes_task_group] = group
      end

      def with(group)
        previous = current
        self.current = group
        yield
      ensure
        self.current = previous
      end
    end

    def initialize
      @tasks = []
      @mutex = Mutex.new
      @stopped = false
      # Completed tasks announce themselves here, so `wait` can surface a
      # failure as soon as it happens instead of in start order (W5-5).
      @completions = Queue.new
    end

    def async(&block)
      stopped = false
      task = nil
      @mutex.synchronize do
        stopped = @stopped
        task = if stopped
                 # Never start the thread: the group is already stopped.
                 Task.new(on_complete: method(:task_completed), autostart: false, &block)
               else
                 Task.new(on_complete: method(:task_completed), &block)
               end
        @tasks << task unless stopped
      end
      task
    end

    # Completion callback; must not raise (it runs in the task's thread).
    def task_completed(task)
      @completions << task
      nil
    end

    def tasks
      @mutex.synchronize { @tasks.dup }
    end

    # Waits for the tasks that were tracked when the call started, in
    # *completion* order. With a block, the block is called with each task as
    # it finishes (used to translate control flow into a stop); the first
    # exception it raises propagates immediately. Without a block, the first
    # task that failed is raised.
    def wait(&block)
      pending = tasks
      return if pending.empty?

      tracked = {}
      pending.each { |task| tracked[task.object_id] = task }
      remaining = pending.length
      while remaining.positive?
        task = @completions.pop
        next unless tracked.delete(task.object_id)

        remaining -= 1
        block ? block.call(task) : task.wait
      end
    end

    # How long #drain waits for stragglers before giving up on them.
    STOP_JOIN_TIMEOUT_S = 5.0

    # Mark the group stopped and REPORT the runes still in flight.
    #
    # It deliberately does not block. A Ruby thread cannot be interrupted
    # mid-call, so joining here would make an abort wait for the slowest
    # sibling — exactly what W5-5 forbids ("the fast failure must not wait for
    # the slow task"). Instead the stragglers stay tracked on the group, are
    # named in a warning, and can be joined with #drain by anyone who wants
    # the guarantee.
    def stop(join_timeout: nil)
      outstanding = []
      @mutex.synchronize do
        @stopped = true
        @tasks.each do |task|
          task.mark_stopped! unless task.finished?
          outstanding << task if task.started? && !task.finished?
        end
      end

      if join_timeout
        stragglers = drain(outstanding, timeout: join_timeout)
        warn_about(stragglers, join_timeout) unless stragglers.empty?
      elsif !outstanding.empty?
        warn "[Workflow] scope stopped with #{outstanding.size} rune(s) still running; " \
             'they cannot be interrupted (give them a timeout) and are tracked on the group'
      end
      outstanding
    end

    # Join the given tasks (default: everything outstanding), bounded by
    # `timeout`. Returns the tasks that were still running when it elapsed.
    def drain(tasks = nil, timeout: STOP_JOIN_TIMEOUT_S)
      pending = tasks || tasks_in_flight
      deadline = Runes::Compat.monotonic + timeout.to_f
      pending.each do |task|
        remaining = deadline - Runes::Compat.monotonic
        break if remaining <= 0

        task.thread&.join(remaining)
      end
      pending.reject { |v| v.finished? }
    end

    # Tasks that started and have not finished.
    def tasks_in_flight
      tasks.select { |task| task.started? && !task.finished? }
    end

    def warn_about(stragglers, timeout)
      warn "[Workflow] #{stragglers.size} rune(s) still running #{timeout}s after the scope stopped; " \
           'they cannot be interrupted mid-call (give them a timeout)'
    end
  end

  # Counting semaphore for `map`'s `parallel(n)` limit. Standard-library only.
  class Semaphore
    def initialize(limit)
      @limit = limit
      @count = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def acquire
      @mutex.synchronize do
        @condition.wait(@mutex) while @count >= @limit
        @count += 1
      end
    end

    def release
      @mutex.synchronize do
        @count -= 1 if @count.positive?
        @condition.signal
      end
    end

    # Acquire around a block, always releasing.
    def synchronize
      acquire
      begin
        yield
      ensure
        release
      end
    end
  end
end
