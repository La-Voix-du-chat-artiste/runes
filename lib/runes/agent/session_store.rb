module Runes
  module Agent
    # Bounded goal-session store with TTL/LRU hygiene.
    module SessionStore
      # The daemon's only open goal session, or nil when there are zero
      # or several (ambiguous — the client must supply its session id).
      def sole_goal_session_id
        goal_sids = @sessions_mutex.synchronize do
          @sessions.select { |_, s| s[:mode] == 'goal' }.keys
        end
        goal_sids.size == 1 ? goal_sids.first : nil
      end

      # ---------- session store hygiene ----------

      MAX_SESSIONS        = 32   # LRU cap on concurrent goal sessions
      SESSION_TTL_S       = 1800 # idle sessions are pruned
      MAX_SESSION_MESSAGES = 40  # keep last N turns (user+assistant) per session

      def open_session(sid)
        @sessions_mutex.synchronize do
          prune_sessions_locked
          session = @sessions[sid]
          unless session
            evict_oldest_session_locked if @sessions.size >= MAX_SESSIONS
            session = { mode: 'goal', messages: [], opened_at: Time.now, mutex: Mutex.new }
            @sessions[sid] = session
          end
          session[:opened_at] = Time.now
          session[:last_turn_at] = Time.now
          session
        end
      end

      def close_session(sid)
        @sessions_mutex.synchronize { @sessions.delete(sid) }
      end

      # Trims history so long goal conversations do not grow the LLM
      # payload (and token cost) without bound. Keeps the most recent
      # turns; the system prompt (passed separately by chat) is never at
      # risk.
      def trim_session_history(session)
        return unless session[:messages].size > MAX_SESSION_MESSAGES

        session[:messages] = session[:messages].last(MAX_SESSION_MESSAGES)
      end

      # A session whose mutex is held (turn in flight) must never be
      # evicted mid-conversation — history would be silently lost.
      def session_busy?(session)
        session[:mutex].locked? rescue false
      end

      def prune_sessions_locked
        ttl = session_ttl
        @sessions.reject! do |_, s|
          next false if session_busy?(s)
          s[:opened_at] < Time.now - ttl
        end
      end

      def evict_oldest_session_locked
        # Prefer evicting by last turn (LRU); never evict a busy session.
        candidates = @sessions.reject { |_, s| session_busy?(s) }
        oldest = candidates.min_by { |_, s| s[:last_turn_at] || s[:opened_at] }
        @sessions.delete(oldest[0]) if oldest
      end

      def session_ttl
        Float(@settings.env('RUNES_SESSION_TTL_S') || SESSION_TTL_S)
      rescue ArgumentError
        SESSION_TTL_S
      end
    end
  end
end
