ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # SQLite is a single-writer store and the observer's own tests assert on
    # the singleton ingest row, so one worker keeps this deterministic.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup do
      # The recorder memoizes "who executed this request" and the ingest
      # heartbeat between calls (it is built for a long-lived process), so
      # tests must clear that state or ordering could leak between them.
      PacketRecorder.reset_cache!
      IngestStatus.delete_all
    end
  end
end
