require_relative '../request_ledger'

module Runes
  module Agent
    # Durable prompt log: JSONL journal append plus rotation.
    module Journal
      # ---------- durable prompt log ----------

      # Append-only session log: every prompt lifecycle end is published
      # as a JSON envelope on `runes/_log/prompts`, mirrored to a durable
      # on-disk JSONL journal (the broker is in-memory — restarts wipe
      # retained state), plus a retained latest-entry snapshot for
      # late-joining observers.
      def record_prompt_log(publisher, request_id, prompt, status:, summary: nil, error: nil)
        entry = {
          'request_id' => request_id,
          'agent'      => @agent_id,
          'prompt'     => loggable_prompt(prompt),
          'status'     => status,
          'at'         => Time.now.utc.iso8601
        }
        entry['summary'] = summary if summary
        entry['error']   = error if error
        payload = JSON.generate(entry)
        publisher.publish(PROMPT_LOG_TOPIC, payload)
        publisher.publish("#{PROMPT_LOG_TOPIC}/latest", payload, retain: true)
        append_journal(payload)
        # The request is finished: remember what it did, so a redelivered copy
        # can be answered from the ledger instead of run again (doc5.md /
        # lib/runes/request_ledger.rb). `&.` because this module is mixed into
        # things that have no ledger.
        @request_ledger&.complete(Runes::RequestLedger.prompt_key(request_id),
                                  [status, summary || error].compact.join(': '))
      rescue => e
        log "Prompt log failed: #{e.message}"
      end

      # S-D3: prompts can carry pasted secrets; the journal and the
      # retained latest-snapshot persist them in plaintext. Operators can
      # opt into redaction with RUNES_REDACT_PROMPTS=1 (default keeps the
      # full text for local debugging).
      def loggable_prompt(prompt)
        if %w[1 true yes on].include?(@settings.env('RUNES_REDACT_PROMPTS').to_s.downcase)
          "[redacted #{Digest::SHA256.hexdigest(prompt.to_s)[0, 12]}]"
        else
          prompt.to_s[0, 2000]
        end
      end

      def journal_path
        File.join(@settings.root, 'log', 'journal.jsonl')
      end

      JOURNAL_ROTATE_BYTES = 10 * 1024 * 1024
      JOURNAL_LOCK = '.journal.lock'.freeze

      def append_journal(payload)
        path = journal_path
        FileUtils.mkdir_p(File.dirname(path))
        # Prompt workers run concurrently; serialize the append so
        # interleaved writes cannot tear a JSONL line.
        @journal_mutex.synchronize do
          # Cross-process safety (B4-7/E4-11): the in-process mutex cannot
          # coordinate a daemon and a CLI, and two rotators used to clobber
          # the single fixed `.1` archive. Hold an exclusive file lock for
          # the whole check-rotate-append.
          with_journal_lock(path) do
            rotate_journal(path) if File.exist?(path) && File.size(path) > JOURNAL_ROTATE_BYTES
            File.open(path, 'a') { |f| f.puts payload }
          end
        end
      rescue => e
        log "Journal append failed: #{e.message}"
      end

      def with_journal_lock(path)
        lock_path = File.join(File.dirname(path), JOURNAL_LOCK)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end

      # Timestamped archive: a fixed `.1` name let two concurrent rotators
      # (daemon + CLI) overwrite each other's archive, silently dropping up
      # to JOURNAL_ROTATE_BYTES of audit trail (B4-7). `bin/runes-replay`
      # reads only the live file, so the archive name is free.
      def rotate_journal(path)
        archive = "#{path}.#{Time.now.utc.strftime('%Y%m%dT%H%M%S%L')}"
        File.rename(path, archive)
        log "Journal rotated to #{File.basename(archive)}"
      rescue => e
        log "Journal rotation failed: #{e.message}"
      end
    end
  end
end
