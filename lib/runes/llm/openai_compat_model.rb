# frozen_string_literal: true

require 'net/http'
require 'timeout'
require 'uri'

require_relative '../compat'
require_relative '../json_facade'

module Runes
  module LLM
    # Minimal OpenAI-compatible chat client for a warm local model server.
    #
    # It is intentionally smaller than Core::LLMClient: no provider registry,
    # no fallback, no key discovery. The base URL, model and sampler are
    # explicit, so a benchmark can pin them.
    class OpenAICompatModel
      attr_reader :base_url, :model_name, :sampler, :timeout_s

      def initialize(base_url:, model:, api_key: nil, timeout_s: 300, sampler: {}, transport: nil)
        @base_url = base_url.to_s.sub(%r{/+\z}, '')
        @model_name = model.to_s
        @api_key = api_key
        @timeout_s = timeout_s.to_f
        @sampler = sampler || {}
        @transport = transport || method(:post_http)
      end

      def call(prompt, role: nil, max_tokens: nil)
        started = Runes::Compat.monotonic
        payload = {
          'model' => @model_name,
          'messages' => [{ 'role' => 'user', 'content' => prompt.to_s }]
        }
        payload['max_tokens'] = max_tokens if max_tokens
        @sampler.each { |key, value| payload[key.to_s] = value unless value.nil? }

        uri = URI.parse("#{@base_url}/chat/completions")
        response = @transport.call(
          uri: uri,
          body: Runes::Json.generate(payload),
          headers: headers,
          timeout_s: @timeout_s
        )
        elapsed = Runes::Compat.monotonic - started
        parse_response(response, elapsed)
      rescue Timeout::Error
        failure(:infra, "model server timed out after #{@timeout_s}s", Runes::Compat.monotonic - started)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, EOFError, SocketError => e
        failure(:infra, "model server unavailable: #{e.class}: #{e.message}", Runes::Compat.monotonic - started)
      rescue StandardError => e
        failure(:error, "#{e.class}: #{e.message}", Runes::Compat.monotonic - started)
      end

      def available?
        !@base_url.empty? && !@model_name.empty?
      end

      def availability_error
        return nil if available?

        'model server needs a base_url and a model name'
      end

      private

      def parse_response(response, elapsed)
        code = response.respond_to?(:code) ? response.code.to_i : 0
        body = response.respond_to?(:body) ? response.body.to_s : ''
        unless code >= 200 && code < 300
          return failure(:infra, "model server HTTP #{code}: #{body[0, 500]}", elapsed)
        end

        parsed = Runes::Json.parse(body)
        message = parsed.dig('choices', 0, 'message') rescue nil
        return failure(:error, 'model server response missing choices[0].message', elapsed) if message.nil?

        content = message['content'].to_s
        return failure(:empty_stop, 'model server returned an empty message', elapsed) if content.strip.empty?

        {
          ok: true,
          content: content,
          usage: parsed['usage'],
          finish_reason: parsed.dig('choices', 0, 'finish_reason'),
          status: :ok,
          error: nil,
          elapsed_s: elapsed
        }
      rescue Runes::Json::ParseError => e
        failure(:error, "model server returned invalid JSON: #{e.message}", elapsed)
      end

      def headers
        base = { 'Content-Type' => 'application/json' }
        base['Authorization'] = "Bearer #{@api_key}" unless @api_key.to_s.empty?
        base
      end

      def post_http(uri:, body:, headers:, timeout_s:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.is_a?(URI::HTTPS)
        http.open_timeout = timeout_s
        http.read_timeout = timeout_s
        http.write_timeout = timeout_s if http.respond_to?(:write_timeout=)
        request = Net::HTTP::Post.new(uri.path, headers)
        request.body = body
        http.request(request)
      end

      def failure(status, message, elapsed)
        {
          ok: false,
          content: nil,
          usage: nil,
          finish_reason: nil,
          status: status,
          error: message,
          elapsed_s: elapsed
        }
      end
    end
  end
end
