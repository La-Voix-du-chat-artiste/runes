# frozen_string_literal: true

require_relative '../json_facade'
require_relative '../sha256_facade'

module Runes
  module LLM
    # Small, dependency-free helpers shared by the LFM3 adapters.
    #
    # The adapters are deliberately thin: they build an explicit argv or an
    # explicit OpenAI-compatible payload, clean the transport's stdout, and
    # attach the model-family facts a receipt needs. Nothing here reaches the
    # network, the filesystem tree, or a model until the caller asks it to.
    module AdapterSupport
      ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/
      CONTROL = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/
      FENCE = /\A```[A-Za-z0-9_+\-]*\s*\n(.*?)\n```\z/m
      # Only *closed* think blocks are stripped — an unclosed <think> must not
      # eat the whole answer (that turned into empty_stop rows).
      THINK = /<think(?:ing)?>.*?<\/think(?:ing)?>/mi

      module_function

      # Merge the common adapter contract onto a backend result.
      #
      # `family` is the model identifier, not the ModelFamily object: run
      # receipts publish it as a string and the conductor already has the
      # object from the manifest.
      def envelope_result(result, family:, modalities:, extra: {})
        out = {
          ok: false,
          content: nil,
          usage: nil,
          finish_reason: nil,
          status: :error,
          error: nil
        }
        result.each { |key, value| out[key.to_sym] = value }
        out[:family] = family.to_s
        out[:modalities] = Array(modalities).map(&:to_s)
        extra.each { |key, value| out[key.to_sym] = value }
        out
      end

      def failure(status, message, family:, modalities:, extra: {})
        envelope_result(
          {
            ok: false, content: nil, usage: nil, finish_reason: nil,
            status: status, error: message, elapsed_s: nil
          },
          family: family,
          modalities: modalities,
          extra: extra
        )
      end

      # Strip ANSI/control tokens, normalize line endings, remove a leading
      # prompt echo, and unwrap a single fenced block. The model command may
      # print its own prompt or a progress preamble; neither is an answer.
      def clean_output(text, prompt: nil)
        clean = text.to_s.dup
        clean = clean.gsub(THINK, '')
        clean = clean.gsub(ANSI, '')
        clean = clean.gsub("\r\n", "\n").gsub("\r", "\n")
        clean = clean.gsub(CONTROL, '')

        if prompt && !prompt.to_s.empty?
          prefix = prompt.to_s
          clean = clean.sub(/\A\s*#{Regexp.escape(prefix)}\s*/, '')
        end

        blocks = clean.split(/^=+\s*$/).map(&:strip).reject(&:empty?)
        answer = blocks.find { |block| !block.match?(/\A(?:Prompt|Generation|Peak memory):/) }
        clean = answer || clean

        clean = clean.strip
        if (match = clean.match(FENCE))
          clean = match[1].strip
        end
        clean
      end

      def stringify_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def path_like?(text)
        value = text.to_s
        return true if value.start_with?('/') || value.start_with?('~') ||
                       value.start_with?('./') || value.start_with?('../')
        return false unless value.include?(File::SEPARATOR)

        # A Hugging Face repository id (owner/name) is not a local path.
        !value.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      end

      def expanded_path(text)
        value = text.to_s
        value.start_with?('~') ? File.expand_path(value) : value
      end

      def file_sha256(path)
        Runes::SHA256.hex(File.binread(path))
      end

      def read_json_object(text)
        stripped = text.to_s.strip
        return Runes::Json.parse(stripped) if stripped.start_with?('{') || stripped.start_with?('[')

        start = stripped.index('{')
        finish = stripped.rindex('}')
        return nil if start.nil? || finish.nil? || finish < start

        Runes::Json.parse(stripped[start..finish])
      rescue Runes::Json::ParseError
        nil
      end
    end
  end
end
