# frozen_string_literal: true

require_relative 'compat'
require_relative 'json_facade'
require_relative 'random_facade'
require_relative 'sha256_facade'

module Runes
  # Per-run workspace shared by the cumulative agents.
  #
  # This is deliberately *not* a conversation transcript and *not*
  # `RequestLedger` (inbound dedupe). It is the small set of artifacts a fresh
  # context needs: the task, the evidence, the draft, the critique, the
  # verifier's violations and the final answer. The transcript is for audit;
  # it is never fed back to the model.
  #
  #   ledger = Runes::WorkLedger.new(root: "tmp/runs", run_id: "g1-2x-s0")
  #   ledger.write(:task, question)
  #   ledger.write_json(:evidence, evidence)
  #   ledger.write(:draft, answer)
  #   ledger.snapshot!(Runes::DocStore.new(root: "tmp/docs"))
  class WorkLedger
    class Error < StandardError; end
    class TooLarge < Error; end
    class InvalidName < Error; end

    MAX_ARTIFACT_BYTES = 1_048_576
    MAX_TRANSCRIPT_BYTES = 8_388_608
    RUN_ID = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

    # The allow-list is the whole path-safety story: a caller never supplies a
    # filename, only a logical section name.
    FILES = {
      task: 'task.md',
      evidence: 'evidence.json',
      draft: 'draft.md',
      critique: 'critique.md',
      violations: 'violations.json',
      final: 'final.md',
      :"draft.cutoff" => 'draft.cutoff.md',
      manifest: 'manifest.json',
      identity: 'identity.json',
      capacities: 'capacities.json',
      decision: 'decision.json',
      decline: 'decline.md',
      checkpoints: 'checkpoints.json',
      role_receipts: 'role_receipts.json',
      triage: 'triage.json',
      plan: 'plan.md',
      perception: 'perception.json',
      notes: 'notes.md',
      proposals: 'proposals.json',
      review: 'review.md',
      test_status: 'test-status.txt',
      test_output: 'test-output.log',
      final_test_output: 'final-test-output.log',
      calibration: 'calibration.json',
      transcript: 'transcript.jsonl'
    }.freeze

    attr_reader :root, :run_id, :dir

    def initialize(root:, run_id:)
      @root = root.to_s
      @run_id = run_id.to_s
      unless @run_id.match?(RUN_ID) && !@run_id.include?('..')
        raise InvalidName, "work ledger: invalid run_id #{run_id.inspect}"
      end

      @dir = File.join(@root, @run_id)
      Runes::Compat.mkdir_p(@dir)
    end

    def write(name, content)
      text = content.to_s
      raise TooLarge, "work ledger: #{name} exceeds #{MAX_ARTIFACT_BYTES} bytes" if text.bytesize > MAX_ARTIFACT_BYTES

      path = path_for(name)
      tmp = File.join(@dir, ".#{File.basename(path)}.tmp-#{Runes::Random.hex(4)}")
      File.open(tmp, 'wb') { |file| file.write(text) }
      File.rename(tmp, path)
      text
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.file?(tmp)
    end

    def write_json(name, object)
      write(name, Runes::Json.generate(object))
    end

    def read(name)
      path = path_for(name)
      File.file?(path) ? File.read(path) : nil
    end

    def read_json(name)
      text = read(name)
      return nil if text.nil? || text.strip.empty?

      Runes::Json.parse(text)
    rescue Runes::Json::ParseError => e
      raise Error, "work ledger: #{name} is not valid JSON: #{e.message}"
    end

    def artifact?(name)
      path = path_for(name)
      File.file?(path) && File.size(path).positive?
    end

    def sha(name)
      text = read(name)
      text && Runes::SHA256.hex(text)
    end

    def manifest
      read_json(:manifest) || {}
    end

    def update_manifest(values)
      current = manifest
      values.each { |key, value| current[key.to_s] = value }
      write_json(:manifest, current)
      current
    end

    def append_transcript(event, **fields)
      entry = {
        'at' => Runes::Compat.utc_iso8601(Time.now),
        'event' => event.to_s
      }
      fields.each { |key, value| entry[key.to_s] = value }
      line = Runes::Json.generate(entry)
      append_line(line)
      entry
    end

    # Keep the partial artifact when a model hits its output cap. The point is
    # to make the cut-off visible and reusable, not to discard the work.
    def preserve_cutoff!(name = :draft, text = nil)
      content = text.nil? ? read(name) : text.to_s
      return nil if content.nil?

      write('draft.cutoff', content)
      append_transcript('cutoff_preserved', section: name.to_s, bytes: content.bytesize)
      content
    end

    # Store every artifact in a content-addressed DocStore. Returns a hash of
    # ledger section => { sha:, path:, bytes: }. The transcript is included so
    # a run can be reconstructed; it is still not a prompt input.
    def snapshot!(doc_store)
      out = {}
      FILES.each_key do |name|
        next if name == :transcript

        text = read(name)
        next if text.nil?

        ext = File.extname(FILES.fetch(name)).sub(/\A\./, '')
        stored = doc_store.put(text, ext: ext)
        out[name.to_s] = stored
      end
      update_manifest('snapshot' => out)
      out
    end

    def transcript
      text = read(:transcript)
      return [] if text.nil? || text.strip.empty?

      text.each_line.filter_map do |line|
        next if line.strip.empty?

        Runes::Json.parse(line)
      rescue Runes::Json::ParseError
        nil
      end
    end

    def files
      FILES.each_key.filter_map do |name|
        path = path_for(name)
        next unless File.file?(path)

        { name: name.to_s, path: path, bytes: File.size(path) }
      end
    end

    private

    def path_for(name)
      key = name.to_sym
      filename = FILES[key]
      raise InvalidName, "work ledger: unknown section #{name.inspect}" if filename.nil?

      File.join(@dir, filename)
    end

    def append_line(line)
      path = path_for(:transcript)
      lock_path = File.join(@dir, '.transcript.lock')
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        current = File.file?(path) ? File.size(path) : 0
        if current + line.bytesize + 1 > MAX_TRANSCRIPT_BYTES
          raise TooLarge, "work ledger: transcript exceeds #{MAX_TRANSCRIPT_BYTES} bytes"
        end

        File.open(path, 'ab') { |file| file.write(line + "\n") }
      end
      line
    end
  end
end
