require "test_helper"
require "tmpdir"

# `runes/_log/prompts` is published *and* appended to a durable JSONL journal.
# The broker is in-memory and the observer is a separate process that can be
# down, so the file is the only history that survives a restart — but only if
# tailing it cannot double-store what the bus already delivered (doc5.md O0.7).
class JournalTailTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    Agent.delete_all
    IngestStatus.delete_all
    PacketRecorder.reset_cache!
    @dir = Dir.mktmpdir("runes-journal-")
    @path = File.join(@dir, "journal.jsonl")
  end

  teardown do
    @tail&.stop
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  test "appended entries are read once, in order, and become journal packets" do
    File.write(@path, "")
    tail = build_tail

    append(entry("req-1", "complete"))
    assert_equal 1, tail.poll_once!
    append(entry("req-2", "planner_error"))
    assert_equal 1, tail.poll_once!
    # Nothing new: no rows, no rereading.
    assert_equal 0, tail.poll_once!

    packets = Packet.where(topic: JournalTail::TOPIC).order(:id).to_a
    assert_equal %w[req-1 req-2], packets.map(&:request_id)
    assert_equal %w[journal journal], packets.map(&:kind)
    assert_equal %w[complete planner_error], packets.map { |p| p.parsed["status"] }
  end

  test "an entry the bus already delivered is not stored twice" do
    line = entry("req-bus", "complete")
    # The observer heard it on the fabric first...
    PacketRecorder.record(topic: JournalTail::TOPIC, payload: line)
    assert_equal 1, Packet.where(request_id: "req-bus").count

    File.write(@path, "#{line}\n")
    tail = build_tail

    # ...so the file adds nothing but a duplicate counter.
    assert_equal 0, tail.poll_once!
    assert_equal 1, Packet.where(request_id: "req-bus").count
    assert_equal 1, tail.duplicates
  end

  test "a partial line is held until its newline arrives" do
    File.write(@path, "")
    tail = build_tail
    line = entry("req-partial", "complete")

    File.write(@path, line[0, line.bytesize - 5], mode: "a")
    assert_equal 0, tail.poll_once!
    assert_equal 0, Packet.where(request_id: "req-partial").count

    File.write(@path, "#{line[-5..]}\n", mode: "a")
    assert_equal 1, tail.poll_once!
    assert_equal 1, Packet.where(request_id: "req-partial").count
  end

  test "rotation is followed: a new file is read from its start" do
    File.write(@path, "#{entry('req-old', 'complete')}\n")
    tail = build_tail
    assert_equal 1, tail.poll_once!

    File.rename(@path, "#{@path}.20260910T000000")
    File.write(@path, "#{entry('req-new', 'complete')}\n")

    assert_equal 1, tail.poll_once!
    assert_equal %w[req-old req-new], Packet.where(topic: JournalTail::TOPIC).order(:id).pluck(:request_id)
  end

  test "truncation re-reads from the start and still cannot duplicate" do
    line = entry("req-trunc", "complete")
    File.write(@path, "#{line}\n")
    tail = build_tail
    assert_equal 1, tail.poll_once!

    File.write(@path, "") # shrank: a copy or a rewrite, not a rotation
    assert_equal 0, tail.poll_once!
    File.write(@path, "#{entry('req-after', 'complete')}\n")
    assert_equal 1, tail.poll_once!

    assert_equal 2, Packet.where(topic: JournalTail::TOPIC).count
  end

  test "a line the recorder cannot store is counted, and the next one still lands" do
    File.write(@path, "")
    tail = build_tail
    append("regression: the recorder explodes")
    append(entry("req-ok", "complete"))

    original = PacketRecorder.method(:record)
    PacketRecorder.define_singleton_method(:record) do |**kwargs|
      raise Encoding::UndefinedConversionError, "boom" if kwargs[:payload].start_with?("regression")

      original.call(**kwargs)
    end
    begin
      assert_equal 1, tail.poll_once!
    ensure
      PacketRecorder.define_singleton_method(:record, original)
    end

    assert_equal 1, tail.failed
    assert Packet.where(request_id: "req-ok").exists?
  end

  # A corrupt line is not special-cased: like the MQTT path, the observer
  # stores what it cannot parse rather than dropping it silently. The row has
  # no request_id, and `packets.scrubbed` is the flag that says so.
  test "an unparseable line is still stored, not dropped" do
    File.write(@path, "not json at all\n")
    tail = build_tail

    assert_equal 1, tail.poll_once!
    assert_equal 0, tail.failed
    packet = Packet.where(topic: JournalTail::TOPIC).first
    assert_nil packet.request_id
    assert_equal "journal", packet.kind
  end

  test "a line that never ends does not grow the buffer without bound" do
    File.write(@path, "")
    tail = build_tail
    File.write(@path, "x" * (JournalTail::MAX_LINE_BYTES + 10), mode: "a")

    assert_equal 0, tail.poll_once!
    assert_equal 1, tail.failed
    assert_equal 0, tail.send(:instance_variable_get, :@buffer).bytesize
  end

  test "the tail follows the harness journal by default, and can be switched off" do
    previous = ENV["RUNES_OBSERVER_JOURNAL"]
    begin
      ENV["RUNES_OBSERVER_JOURNAL"] = "off"
      assert_nil JournalTail.build(logger: Logger.new(IO::NULL))

      ENV["RUNES_OBSERVER_JOURNAL"] = @path # explicit: waited for, not required
      tail = JournalTail.build(logger: Logger.new(IO::NULL))
      assert_equal @path, tail.path

      ENV.delete("RUNES_OBSERVER_JOURNAL")
      # The default points at the sibling harness checkout and only exists
      # when a harness has actually written one.
      assert_includes JournalTail.default_path, "log/journal.jsonl"
    ensure
      previous.nil? ? ENV.delete("RUNES_OBSERVER_JOURNAL") : ENV["RUNES_OBSERVER_JOURNAL"] = previous
    end
  end

  private

  def build_tail
    @tail = JournalTail.new(path: @path, logger: Logger.new(IO::NULL), interval: 0)
  end

  def append(line)
    File.write(@path, "#{line}\n", mode: "a")
  end

  def entry(request_id, status)
    JSON.generate("request_id" => request_id, "agent" => "runes-alpha", "prompt" => "do a thing",
                  "status" => status, "at" => Time.now.utc.iso8601)
  end
end
