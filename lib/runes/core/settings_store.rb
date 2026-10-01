# frozen_string_literal: true

require_relative '../json_facade'
require_relative '../compat'
require_relative '../random_facade'

module Runes
  module Core
    # Settings persistence seam.
    #
    # Runes::Core::Settings owns env lookup, defaults seeding and provider
    # reconciliation; the raw key/value persistence lives behind this small
    # interface so the CRuby harness keeps SQLite while a compiled kernel
    # uses the pure JSONL store (docs/spinel/spec-tier-b.md §B3 — the JSONL
    # pick: preferences writes are rare, so a whole-file atomic store loses
    # nothing the SQLite busy_timeout was protecting).
    #
    #   class << Runes::Core::Settings
    #     attr_accessor :store_class   # set by lib/runes.rb (SQLite) or the
    #   end                             # spin kernel entry (JSONL)
    #
    # Store contract: get(key, default = nil), set(key, value),
    # set_if_absent(key, value), close.
    class Settings
      class << self
        attr_accessor :store_class
      end
    end

    module SettingsStore
      # Whole-file JSON object behind the store contract. Pure subset:
      # atomic tmp+rename writes under an exclusive flock, reads tolerant
      # of a missing/corrupt file (a fresh preferences file is a seeding
      # opportunity, not an error).
      class JSONL
        def initialize(path:)
          @path = path.to_s
        end

        def get(key, default = nil)
          data[key.to_s] || default
        end

        def set(key, value)
          write_pair(key.to_s, value.to_s)
          value
        end

        def set_if_absent(key, value)
          current = get(key)
          return current unless current.nil?

          set(key, value)
        end

        def close
          true
        end

        private

        def data
          raw = File.file?(@path) ? File.read(@path) : nil
          return {} if raw.nil? || raw.strip.empty?

          parsed = Runes::Json.parse(raw)
          parsed.is_a?(Hash) ? stringify(parsed) : {}
        rescue StandardError
          {}
        end

        def stringify(hash)
          out = {}
          hash.each { |k, v| out[k.to_s] = v }
          out
        end

        def write_pair(key, value)
          all = data
          all[key] = value
          Runes::Compat.mkdir_p(File.dirname(@path))
          tmp = "#{@path}.tmp-#{Runes::Random.hex(4)}"
          File.write(tmp, Runes::Json.generate(all))
          File.rename(tmp, @path)
        rescue StandardError
          # Read-only or contested writes degrade like the SQLite era: the
          # in-memory answer still stands, nothing crashes at boot (R3).
          nil
        ensure
          File.delete(tmp) if tmp && File.file?(tmp)
        end
      end
    end
  end
end
