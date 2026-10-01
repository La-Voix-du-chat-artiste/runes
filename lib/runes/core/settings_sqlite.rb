# frozen_string_literal: true

# CRuby store: SQLite behind the SettingsStore contract — the exact storage
# engine the harness has always used (busy_timeout, WAL, INSERT OR REPLACE,
# read-only tolerance), moved out of settings.rb so that file compiles under
# Spinel. Wired by lib/runes.rb; never loaded by the spin kernel entry.
require 'sqlite3'

require_relative 'settings_store'

module Runes
  module Core
    module SettingsStore
      class SQLite
        def initialize(path:)
          @db = SQLite3::Database.new(path)
          begin
            @db.busy_timeout = 5000
            @db.execute('PRAGMA journal_mode=WAL')
          rescue SQLite3::Exception
            nil # pragma unsupported — proceed anyway
          end
          @db.execute <<-SQL
            CREATE TABLE IF NOT EXISTS preferences (
              key TEXT PRIMARY KEY,
              value TEXT
            );
          SQL
        end

        def get(key, default = nil)
          row = @db.get_first_row('SELECT value FROM preferences WHERE key = ?', [key.to_s])
          row ? row[0] : default
        end

        def set(key, value)
          @db.execute('INSERT OR REPLACE INTO preferences (key, value) VALUES (?, ?)', [key.to_s, value.to_s])
          value
        end

        def set_if_absent(key, value)
          current = get(key)
          return current unless current.nil?

          set(key, value)
        end

        def close
          @db.close rescue nil
          true
        end
      end
    end
  end
end
