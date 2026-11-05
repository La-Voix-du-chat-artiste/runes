# frozen_string_literal: true

module Runes
  module Orchestration
    # One reason a model artifact is not accepted. Errors block acceptance;
    # warnings are recorded in the receipt but do not trigger a repair.
    class Violation
      attr_reader :code, :message, :severity, :detail

      def initialize(code:, message:, severity: :error, detail: nil)
        @code = code.to_s
        @message = message.to_s
        @severity = severity.to_sym
        @detail = detail
      end

      def error?
        severity == :error
      end

      def warn?
        severity == :warn
      end

      def to_h
        {
          'code' => code,
          'message' => message,
          'severity' => severity.to_s,
          'detail' => detail
        }
      end
    end
  end
end
