# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/request_ledger"

# Shared subscriptions make distribution exactly-once; this is the execution
# half. A redelivered QoS 1 PUBLISH, a session-expiry replay or a publisher
# retry must not run one request twice — and the ledger must not become a
# memory leak with a TTL bolted on.
class RequestLedgerTest < Minitest::Test
  # A clock the test drives, so no sleeps and no flakes.
  class FakeClock
    def initialize(now = 1000.0) = @now = now
    def call = @now
    def advance(seconds) = @now += seconds
  end

  def setup
    @clock = FakeClock.new
    @ledger = Runes::RequestLedger.new(ttl: 60, max: 4, clock: @clock)
  end

  def test_the_first_claim_wins_and_the_second_does_not
    key = Runes::RequestLedger.prompt_key("abc")

    assert @ledger.claim(key)
    refute @ledger.claim(key)
    refute @ledger.claim(key)

    assert_equal 1, @ledger.claimed
    assert_equal 2, @ledger.duplicates
    assert_equal 1, @ledger.size
  end

  def test_different_requests_do_not_collide
    assert @ledger.claim(Runes::RequestLedger.prompt_key("one"))
    assert @ledger.claim(Runes::RequestLedger.prompt_key("two"))
    assert @ledger.claim(Runes::RequestLedger.tool_key("read_file", "one"))

    assert_equal 3, @ledger.size
  end

  def test_a_claim_expires_after_its_ttl
    key = Runes::RequestLedger.prompt_key("abc")
    assert @ledger.claim(key)

    @clock.advance(59)
    refute @ledger.claim(key), "inside the window it is still a duplicate"

    @clock.advance(2)
    assert @ledger.claim(key), "past the TTL a request id may legitimately be reused"
  end

  def test_the_outcome_of_the_first_copy_is_kept_for_replays
    key = Runes::RequestLedger.prompt_key("abc")
    @ledger.claim(key)
    assert_nil @ledger.outcome(key), "while the first copy runs there is no outcome yet"

    @ledger.complete(key, "complete: wrote lib/x.rb")
    refute @ledger.claim(key)
    assert_equal "complete: wrote lib/x.rb", @ledger.outcome(key)
  end

  def test_an_outcome_is_a_receipt_not_a_result_store
    key = Runes::RequestLedger.prompt_key("big")
    @ledger.claim(key)
    @ledger.complete(key, "x" * 5_000)

    outcome = @ledger.outcome(key)
    assert_operator outcome.bytesize, :<=, Runes::RequestLedger::MAX_OUTCOME_BYTES + 3
    assert outcome.end_with?("…")
  end

  def test_an_expired_key_forgets_its_outcome_too
    key = Runes::RequestLedger.prompt_key("abc")
    @ledger.claim(key)
    @ledger.complete(key, "complete")

    @clock.advance(61)
    assert_nil @ledger.outcome(key)
    refute @ledger.seen?(key)
  end

  # A long-lived agent must not accumulate keys: the cap is a cap, and the
  # oldest key goes first.
  def test_the_ledger_is_bounded_and_evicts_the_oldest
    6.times { |i| @ledger.claim(Runes::RequestLedger.prompt_key("req-#{i}")) }

    assert_equal 4, @ledger.size
    assert @ledger.seen?(Runes::RequestLedger.prompt_key("req-5"))
    refute @ledger.seen?(Runes::RequestLedger.prompt_key("req-0")),
           "the oldest claim is the one dropped"
  end

  def test_expiry_frees_space_before_the_cap_does
    3.times { |i| @ledger.claim(Runes::RequestLedger.prompt_key("old-#{i}")) }
    @clock.advance(61)
    @ledger.claim(Runes::RequestLedger.prompt_key("new"))

    assert_equal 1, @ledger.size
  end

  def test_prune_drops_only_expired_keys
    @ledger.claim(Runes::RequestLedger.prompt_key("old"))
    @clock.advance(30)
    @ledger.claim(Runes::RequestLedger.prompt_key("fresh"))
    @clock.advance(31) # old is now 61s old, fresh is 31s

    assert_equal 1, @ledger.prune!
    assert @ledger.seen?(Runes::RequestLedger.prompt_key("fresh"))
  end

  # The whole point: two transport threads delivering the same message at the
  # same time must produce exactly one winner.
  def test_concurrent_claims_produce_exactly_one_winner
    key = Runes::RequestLedger.prompt_key("race")
    winners = Queue.new
    threads = 16.times.map do
      Thread.new { winners << 1 if @ledger.claim(key) }
    end
    threads.each(&:join)

    assert_equal 1, winners.size
    assert_equal 15, @ledger.duplicates
  end

  def test_reset_clears_everything
    @ledger.claim(Runes::RequestLedger.prompt_key("abc"))
    @ledger.reset!

    assert_equal 0, @ledger.size
    assert_equal 0, @ledger.duplicates
    assert @ledger.claim(Runes::RequestLedger.prompt_key("abc"))
  end
end
