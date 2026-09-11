require "json"

# The durable half of `runes/_log/prompts` (doc5.md O0.7).
#
# The harness publishes every prompt-lifecycle end on that topic **and**
# appends the same payload to a JSONL journal (`<root>/log/journal.jsonl`,
# rotated at 10 MB, flock-protected). The broker is in-memory and the observer
# is a separate process that can be down, restarted, or simply not subscribed
# when a prompt finishes — so the file is the only source that survives a
# broker restart. Tailing it is what turns "the harness keeps a durable
# journal" from a claim about the harness into history the console shows.
#
# The tail is deliberately dull: it follows one path, tracks inode and byte
# offset, emits only complete lines, and asks the database whether the line is
# already stored. That last part is what makes running both sources safe — an
# entry the observer already heard on the bus is not stored twice, and a
# restart (or a truncation) that re-reads from zero cannot duplicate rows
# either. Two sources, one row.
class JournalTail
  TOPIC = "runes/_log/prompts"
  DEFAULT_INTERVAL_S = 2.0
  # A pathological writer must not be able to make the tail hold an unbounded
  # partial line in memory.
  MAX_LINE_BYTES = 64 * 1024
  OFF = %w[off no none false 0].freeze

  attr_reader :path, :offset, :inode, :read, :duplicates, :failed

  # Build from the environment:
  #
  #   unset                 → the sibling harness checkout's journal, if it exists
  #   RUNES_OBSERVER_JOURNAL=<path>  → tail that path (even before it exists)
  #   RUNES_OBSERVER_JOURNAL=off     → do not tail
  #
  # The default requires the file to exist, because an observatory that is not
  # co-located with a harness would otherwise poll a path that will never
  # appear; an explicit path is taken as an instruction and waited for.
  def self.build(logger: Rails.logger)
    setting = ENV["RUNES_OBSERVER_JOURNAL"].to_s.strip
    return nil if OFF.include?(setting.downcase)

    if setting.empty?
      path = default_path
      return nil unless File.exist?(path)
    else
      path = setting
    end

    new(path: path, logger: logger,
        interval: ENV.fetch("RUNES_OBSERVER_JOURNAL_INTERVAL_S", DEFAULT_INTERVAL_S.to_s).to_f)
  end

  def self.default_path
    File.expand_path("../log/journal.jsonl", Rails.root)
  end

  def initialize(path:, logger: Rails.logger, interval: DEFAULT_INTERVAL_S)
    @path = path.to_s
    @logger = logger
    @interval = interval.to_f
    @offset = 0
    @inode = nil
    @buffer = +""
    @read = 0
    @duplicates = 0
    @failed = 0
    @stopping = false
    @thread = nil
  end

  def start
    return @thread if @thread&.alive?

    @thread = Thread.new do
      until @stopping
        begin
          poll_once!
        rescue StandardError => e
          @failed += 1
          log "tail error: #{e.class}: #{e.message}"
        end
        sleep @interval if @interval.positive?
      end
    end
    @thread.name = "runes-journal-tail" if @thread.respond_to?(:name=)
    @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
    @thread
  end

  def stop
    @stopping = true
    @thread&.kill
    @thread = nil
  end

  # One pass: read everything appended since the last one and store the
  # complete lines. Returns how many rows were written. Never raises — a
  # missing file is normal (the harness may not be running) and a locked or
  # half-written one is temporary.
  def poll_once!
    @offset = 0 if @inode && !File.exist?(@path)
    return 0 unless File.exist?(@path)

    recorded = 0
    File.open(@path, "rb") do |file|
      stat = file.stat
      if stat.ino != @inode
        log "following #{@path} (inode #{stat.ino})" if @inode
        @inode = stat.ino
        @offset = 0
        @buffer = +""
      elsif stat.size < @offset
        # Truncated rather than rotated (a copy or a rewrite): start over.
        log "#{@path} shrank to #{stat.size} bytes; re-reading from the start"
        @offset = 0
        @buffer = +""
      end

      file.seek(@offset)
      chunk = file.read.to_s
      @offset = file.pos
      @buffer << chunk.dup.force_encoding(Encoding::UTF_8).scrub
      recorded += drain_lines
      drop_oversized_partial
    end
    recorded
  end

  private

  def drain_lines
    recorded = 0
    while (index = @buffer.index("\n"))
      line = @buffer.slice!(0, index + 1)
      recorded += 1 if consume(line.chomp)
    end
    recorded
  end

  # A line that never ends cannot be stored, and must not grow forever.
  def drop_oversized_partial
    return if @buffer.bytesize <= MAX_LINE_BYTES

    @failed += 1
    log "dropped a #{@buffer.bytesize}-byte journal line with no newline"
    @buffer = +""
  end

  def consume(line)
    text = line.to_s
    return false if text.strip.empty?

    if already_stored?(text)
      @duplicates += 1
      return false
    end

    PacketRecorder.record(topic: TOPIC, payload: text)
    @read += 1
    true
  rescue StandardError => e
    @failed += 1
    log "dropped journal line: #{e.class}: #{e.message}"
    false
  end

  # The cross-source check: the same payload may already be here because the
  # observer heard it on `runes/_log/prompts`, because a previous process read
  # it, or because we re-read the file after a truncation.
  def already_stored?(text)
    Packet.where(topic: TOPIC, payload: text).exists?
  end

  def log(message)
    @logger.info("[observer] journal: #{message}") if @logger.respond_to?(:info)
  end
end
