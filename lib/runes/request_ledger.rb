# frozen_string_literal: true

module Runes
  # Inbound dedupe: the execution half of "exactly once".
  #
  # Shared subscriptions make *distribution* exactly-once — MQTT 5 hands each
  # prompt to one member of `$share/runes-prompts/runes/prompts`, which is what
  # replaced the claim/lease protocol. **Execution** was never covered:
  #
  #   * a QoS 1 PUBLISH whose PUBACK is lost is retransmitted, and the adapter
  #     delivers it to the handler a second time;
  #   * a client configured with a session expiry gets its unacknowledged
  #     messages back after a reconnect;
  #   * any publisher that retries on timeout does the same.
  #
  # Nothing deduped any of that, so one prompt could run twice: two LLM bills
  # and two sets of tool side effects from one request. This ledger is the
  # smallest thing that closes the window:
  #
  #   ledger.claim(RequestLedger.prompt_key("abc"))   # true first time only
  #   ledger.complete(RequestLedger.prompt_key("abc"), "complete: wrote lib/x.rb")
  #   ledger.outcome(RequestLedger.prompt_key("abc")) # for a replay, not a re-run
  #
  # ## Scope, stated rather than implied
  #
  # The ledger is in-process, bounded and TTL'd. It covers redelivery and
  # application retries inside one process lifetime, which is where the
  # exposure lives: the MQTT 5 adapter connects with `session_expiry: 0` (a
  # clean session), so the broker does not replay messages from before a
  # disconnect. A deployment that turns session expiry on *and* restarts should
  # expect re-runs; a durable ledger (the `sqlite3` the harness already depends
  # on) is the next step if that ever matters. It also cannot dedupe what has no
  # identity: a plain prompt's id is a digest of its text, so two deliberate
  # repeats of the same line are indistinguishable from one retry, and
  # suppressing a user's second identical prompt would be worse than re-running
  # it. Only envelopes that name a `request_id` are deduped.
  class RequestLedger
    DEFAULT_TTL_S = 900
    DEFAULT_MAX = 4096

    Entry = Struct.new(:at, :outcome, keyword_init: true)

    attr_reader :ttl, :max, :duplicates, :claimed

    # @param ttl [Numeric] seconds a claim stays valid
    # @param max [Integer] hard cap on remembered keys
    # @param clock [#call] monotonic seconds; a seam so tests need no sleeps
    def initialize(ttl: DEFAULT_TTL_S, max: DEFAULT_MAX, clock: nil)
      @ttl = ttl.to_f
      @max = [max.to_i, 1].max
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @entries = {}
      @mutex = Mutex.new
      @duplicates = 0
      @claimed = 0
    end

    # True the first time a key is seen inside the TTL, false afterwards.
    # Atomic: two threads delivering the same message cannot both win.
    #
    # One TTL for the whole ledger on purpose: a per-claim window reads as
    # flexibility and behaves as a trap, because the *next* claim decides
    # whether the first one has expired (and would use its own window).
    def claim(key)
      token = key.to_s
      return false if token.empty?

      now = @clock.call
      @mutex.synchronize do
        entry = @entries[token]
        if entry && !expired?(entry, now)
          @duplicates += 1
          return false
        end

        @entries.delete(token) # re-insert so insertion order is also age order
        @entries[token] = Entry.new(at: now)
        evict!(now)
        @claimed += 1
        true
      end
    end

    # Remember what the first copy did, so a replay can be answered instead of
    # re-run. Truncated: this is a receipt, not a result store.
    MAX_OUTCOME_BYTES = 512

    def complete(key, outcome)
      token = key.to_s
      return nil if token.empty?

      text = outcome.to_s
      text = "#{text.byteslice(0, MAX_OUTCOME_BYTES).to_s.scrub}…" if text.bytesize > MAX_OUTCOME_BYTES
      @mutex.synchronize do
        entry = @entries[token]
        if entry
          entry.outcome = text
        else
          @entries[token] = Entry.new(at: @clock.call, outcome: text)
        end
      end
      text
    end

    # The remembered outcome, or nil when the key is unknown/expired (or the
    # first copy is still running).
    def outcome(key)
      token = key.to_s
      now = @clock.call
      @mutex.synchronize do
        entry = @entries[token]
        return nil if entry.nil? || expired?(entry, now)

        entry.outcome
      end
    end

    def seen?(key)
      !outcome_seen(key).nil?
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    def reset!
      @mutex.synchronize do
        @entries.clear
        @duplicates = 0
        @claimed = 0
      end
      true
    end

    # Drop everything past its TTL now (the ledger also prunes on insert).
    def prune!
      now = @clock.call
      @mutex.synchronize do
        @entries.delete_if { |_key, entry| expired?(entry, now) }
        @entries.size
      end
    end

    # --- key namespaces, so two subsystems cannot collide ------------------

    def self.prompt_key(request_id)
      "prompt:#{request_id}"
    end

    def self.tool_key(tool_id, request_id)
      "tool:#{tool_id}:#{request_id}"
    end

    private

    def outcome_seen(key)
      token = key.to_s
      now = @clock.call
      @mutex.synchronize do
        entry = @entries[token]
        entry && !expired?(entry, now) ? entry : nil
      end
    end

    def expired?(entry, now)
      @ttl.positive? && (now - entry.at) > @ttl
    end

    # A bounded ledger is the whole point: a long-lived agent must not be a
    # memory leak with a TTL bolted on. Expired entries go first; if the cap is
    # still reached, the oldest key is dropped — and `claim` is the only
    # insertion point, so insertion order is age order.
    def evict!(now)
      @entries.delete_if { |_key, entry| expired?(entry, now) }
      @entries.shift while @entries.size > @max
    end
  end
end
