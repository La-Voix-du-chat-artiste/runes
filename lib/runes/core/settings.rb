require 'sqlite3'
require 'dotenv'
require_relative 'llm_client'

module Runes
  module Core
    class Settings
      # Resolve paths relative to the project root (two levels up from lib/runes/core/).
      ROOT = File.expand_path('../../../..', __FILE__)
      ENV_PATH = File.join(ROOT, 'config', '.env') # referenced by tests + live smoke

      # Secrets parsed from config/.env. They are deliberately NOT loaded
      # into global ENV (S-R1): provider API keys must never leak into
      # `run_command` child shells. Access goes through #env, which
      # checks real ENV first (Dotenv.load semantics: existing ENV wins).
      @dotenv_cache = {} # path => hash (Dotenv.load is order-dependent — memoize, enhancement)
      @dotenv_mutex = Mutex.new

      class << self
        def dotenv_for(path)
          @dotenv_mutex.synchronize do
            @dotenv_cache[path] ||= File.exist?(path) ? Dotenv.parse(path) : {}
          end
        end
      end

      # B4-13: the whole project root (preferences DB, journal, docs,
      # policy, tools) can be redirected with RUNES_ROOT so tests and
      # embeds never write into the developer's checkout.
      def self.default_root
        override = ENV['RUNES_ROOT'].to_s
        override.empty? ? ROOT : override
      end

      def initialize(root: self.class.default_root)
        @root = root
        @env_path = File.join(@root, 'config', '.env')
        @db_path = File.join(@root, 'runes.db')
        @db = SQLite3::Database.new(@db_path)
        # Multi-process contention (daemon + `runes` CLI) must not crash
        # on an immediate SQLite3::BusyException (R1).
        begin
          @db.busy_timeout = 5000
          @db.execute('PRAGMA journal_mode=WAL')
        rescue SQLite3::Exception
          nil # pragma unsupported — proceed anyway
        end
        @mutex = Mutex.new # SQLite3::Database is not thread-safe
        setup_db
        seed_defaults_safely
        reconcile_provider_preference
      end

      def get(key, default = nil)
        @mutex.synchronize { get_unlocked(key, default) }
      end

      def get_unlocked(key, default = nil)
        row = @db.get_first_row('SELECT value FROM preferences WHERE key = ?', [key])
        row ? row[0] : default
      end

      # Setting the provider re-derives default_model when the stored
      # model does not belong to the new provider (R4) — DB state must
      # not silently lie after a provider switch.
      def set(key, value)
        @mutex.synchronize { set_unlocked(key, value) }
        rederive_model_for_provider(value) if key.to_s == 'default_provider'
        value
      end

      # Env lookup precedence: real ENV (explicit override) > config/.env.
      # Secrets stay OUT of the child-process environment (S-R1).
      def env(key)
        ENV.key?(key) ? ENV[key] : dotenv[key]
      end

      def root
        @root
      end

      def workspace_root
        # User-modifiable workspace for tool side-effects (write_file, etc.).
        # Override with RUNES_WORKSPACE. The default is deliberately
        # DETERMINISTIC (project-local `workspace/`), never the process
        # launch directory — a daemon started from an arbitrary cwd must
        # never scatter tool writes there (this actually happened: files
        # landed in ~/Boxes because the old default was Dir.pwd).
        env('RUNES_WORKSPACE') || File.join(@root, 'workspace')
      end

      def close
        @mutex.synchronize { @db.close rescue nil }
      end

      private

      def dotenv
        self.class.dotenv_for(@env_path)
      end

      def setup_db
        @mutex.synchronize do
          @db.execute <<-SQL
            CREATE TABLE IF NOT EXISTS preferences (
              key TEXT PRIMARY KEY,
              value TEXT
            );
          SQL
        end
      end

      # Seeding is an optimization for fresh DBs, not a boot requirement:
      # read-only consumers must still boot (R3). All keys in one
      # transaction so seeding is atomic and cheap (enhancement).
      def seed_defaults_safely
        @mutex.synchronize do
          @db.transaction
          seed_defaults
          @db.commit
        rescue SQLite3::ReadOnlyException, SQLite3::BusyException, SQLite3::Exception
          begin
            @db.rollback
          rescue SQLite3::Exception
            nil
          end
        end
      end

      def set_unlocked(key, value)
        @db.execute('INSERT OR REPLACE INTO preferences (key, value) VALUES (?, ?)', [key, value])
      end

      def seed_defaults
        # Seed only missing keys so user overrides via `set` survive restarts.
        # Provider preference: explicit env > whichever registered provider
        # has an API key configured (Synthetic first) > cerebras.
        seeded_provider = env('RUNES_DEFAULT_PROVIDER')
        seeded_provider = nil if seeded_provider && seeded_provider.strip.empty?
        seeded_provider ||= Runes::Core::LLMClient::PROVIDER_PREFERENCE.find do |name|
          Runes::Core::LLMClient::PROVIDERS[name]&.key_envs&.any? { |e| (k = env(e)) && !k.strip.empty? }
        end
        seeded_provider ||= 'cerebras'

        set_unlocked('default_provider', seeded_provider) unless get_unlocked('default_provider')
        set_unlocked('default_model', env('RUNES_DEFAULT_MODEL') ||
                                      Runes::Core::LLMClient.seed_model_for(seeded_provider) ||
                                      'llama-3.3-70b') unless get_unlocked('default_model')
        set_unlocked('default_variation', env('RUNES_DEFAULT_VARIATION') || 'high') unless get_unlocked('default_variation')
      end

      def rederive_model_for_provider(provider)
        return unless provider.is_a?(String) && Runes::Core::LLMClient::PROVIDERS.key?(provider)

        current = @mutex.synchronize { get_unlocked('default_model') }.to_s
        seed = Runes::Core::LLMClient.seed_model_for(provider).to_s
        p_def = Runes::Core::LLMClient::PROVIDERS[provider]
        known = current.empty? ||
                current.downcase.start_with?(p_def.model_prefix) ||
                p_def.aliases.key?(current.downcase) ||
                current == seed
        set('default_model', seed) unless known
      end

      # A stale provider preference (e.g. a Cerebras-era runes.db when only
      # a DeepSeek key is configured) is migrated to the first provider in
      # PROVIDER_PREFERENCE that actually has a key. An explicitly chosen
      # provider that HAS a key is never touched (E4-1).
      def reconcile_provider_preference
        @mutex.synchronize do
          current = get_unlocked('default_provider').to_s
          next if current.empty? || provider_key?(current)

          preferred = Runes::Core::LLMClient::PROVIDER_PREFERENCE.find { |name| provider_key?(name) }
          next if preferred.nil? || preferred == current

          set_unlocked('default_provider', preferred)
          set_unlocked('default_model', Runes::Core::LLMClient.seed_model_for(preferred) || preferred)
          set_unlocked('default_variation', 'high') if get_unlocked('default_variation').to_s.strip.empty?
        end
      rescue SQLite3::Exception
        nil # a read-only DB must not break boot (R3)
      end

      def provider_key?(name)
        Runes::Core::LLMClient::PROVIDERS[name]&.key_envs&.any? do |e|
          (k = env(e)) && !k.strip.empty?
        end
      end
    end
  end
end
