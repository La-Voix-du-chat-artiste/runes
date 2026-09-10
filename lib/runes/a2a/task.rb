require "json"
require "securerandom"

module Runes
  module A2A
    # A2A task/message shapes, plus a bridge to Runes' legacy prompt
    # envelope so both speak through one code path in the dispatcher.
    module Task
      STATES = %w[
        submitted working input-required completed canceled failed rejected auth-required unknown
      ].freeze

      TERMINAL_STATES = %w[completed canceled failed rejected].freeze

      module_function

      # { "taskId" => …, "message" => { "role" => "user", "parts" => [...] }, "metadata" => {...} }
      def request(prompt:, task_id: nil, session_id: nil, metadata: {})
        {
          "taskId" => (task_id || "task-#{SecureRandom.hex(4)}"),
          "message" => {
            "role" => "user",
            "messageId" => SecureRandom.uuid,
            "parts" => [{ "kind" => "text", "text" => prompt.to_s }]
          },
          "metadata" => { "sessionId" => session_id }.compact.merge(metadata)
        }
      end

      def task_id(task)
        task.is_a?(Hash) ? (task["taskId"] || task.dig("message", "taskId")).to_s : ""
      end

      # Concatenates every text part (A2A messages are multipart).
      def prompt_from(task)
        return "" unless task.is_a?(Hash)

        parts = task.dig("message", "parts")
        return task["prompt"].to_s if parts.nil? && task["prompt"]

        Array(parts).filter_map do |part|
          next unless part.is_a?(Hash)

          part["text"] if part["kind"].to_s == "text" || part["text"]
        end.join("\n")
      end

      def status(state:, message: nil, artifacts: [])
        raise ArgumentError, "unknown A2A task state #{state.inspect}" unless STATES.include?(state)

        {
          "status" => { "state" => state, "message" => message }.compact,
          "artifacts" => artifacts,
          "final" => TERMINAL_STATES.include?(state)
        }
      end

      def parse(payload)
        data = payload.is_a?(String) ? JSON.parse(payload) : payload
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      # --- bridge to the legacy Runes envelope ---------------------------

      # Turn an A2A task into the envelope the pipeline already understands.
      # Ids become MQTT topic fragments on the reply path, so a hostile
      # `taskId` ("#", "a/../../x") must not flow through: it produced an
      # invalid reply topic and silently dropped the task (doc5.md T5-12).
      # A generated id is used when the peer's id is unusable.
      def safe_task_id(task)
        id = task_id(task).to_s
        return id if id.match?(/\A[A-Za-z0-9_-]{1,32}\z/)

        "a2a-#{SecureRandom.hex(8)}"
      end

      def to_envelope(task, mode: "build")
        {
          request_id: safe_task_id(task),
          prompt: prompt_from(task),
          mode: mode,
          session_id: task.dig("metadata", "sessionId"),
          from_envelope: true
        }
      end

      # Expose a Runes prompt envelope as an A2A task (for peers that only
      # speak A2A).
      def from_envelope(env)
        request(prompt: env[:prompt].to_s,
                task_id: env[:request_id].to_s,
                session_id: env[:session_id],
                metadata: { "mode" => env[:mode].to_s })
      end
    end
  end
end
