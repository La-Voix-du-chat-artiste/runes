# frozen_string_literal: true

require_relative '../core/section_parser'
require_relative '../json_facade'
require_relative 'identity'
require_relative 'capacity'
require_relative 'decision'

module Runes
  module Swarm
    # Tolerant parse of the IDENTITY / CAPACITIES / DECISION / BODY contract.
    #
    # A model is not a parser. It may use `###`, `**`, `KEY:` or JSON, and it
    # may forget a block. This class never raises for a missing or malformed
    # block: it exposes nil objects and keeps the raw fields so `ContractGuard`
    # can explain exactly which contract rule failed.
    class Envelope
      IDENTITY_KEYS = %w[agent_id version role base_model adapter adapter_sha256].freeze
      IDENTITY_REQUIRED = (IDENTITY_KEYS - ['adapter_sha256']).freeze
      CAPACITY_KEYS = %w[can cannot max_input_tokens max_output_tokens output_schema].freeze
      CAPACITY_REQUIRED = CAPACITY_KEYS.freeze
      NULLISH = %w[null none nil - n/a].freeze

      KV = /\A(?:[-*]\s*)?["']?([A-Za-z_][A-Za-z0-9_]*)["']?\s*[:=]\s*(.*?)\s*,?\z/
      QUOTES = /\A["']|["']\z/

      attr_reader :raw, :identity, :capacity, :decision, :body,
                  :identity_fields, :capacity_fields, :decision_fields,
                  :identity_error, :capacity_error, :decision_error

      def identity_present?
        @identity_present
      end

      def capacity_present?
        @capacity_present
      end

      def decision_present?
        @decision_present
      end

      def self.parse(text)
        new(text)
      end

      # Build the envelope for a structured role. `d1` is not a chat model and
      # cannot echo a text contract; the adapter stamps the assigned identity
      # and capacity around the typed artifact. The model never chooses its
      # identity, and the receipt records `identity_source: adapter`.
      def self.stamp(manifest:, decision:, body: '')
        raise ArgumentError, 'envelope: manifest is required' if manifest.nil?
        raise ArgumentError, 'envelope: decision is required' if decision.nil?

        envelope = allocate
        envelope.send(:initialize_stamp, manifest, decision, body)
        envelope
      end

      def initialize(text)
        @raw = text.to_s.dup.freeze
        @identity = @capacity = @decision = nil
        @identity_fields = {}.freeze
        @capacity_fields = {}.freeze
        @decision_fields = {}.freeze
        @identity_error = @capacity_error = @decision_error = nil
        @body = ''.freeze
        @identity_present = @capacity_present = @decision_present = false
        @body_present = false

        parse_json_object(@raw) || parse_sections(@raw)
        @body = @body.dup.freeze
        freeze
      end

      def initialize_stamp(manifest, decision, body)
        @raw = ''.freeze
        @identity = manifest.identity
        @capacity = manifest.capacity
        @decision = decision
        @identity_fields = manifest.identity.to_h.freeze
        @capacity_fields = manifest.capacity.to_h.freeze
        @decision_fields = decision.to_h.reject { |key, _| key == 'body' }.freeze
        @body = body.to_s.dup.freeze
        @identity_error = @capacity_error = @decision_error = nil
        @identity_present = @capacity_present = @decision_present = true
        @body_present = !@body.empty?
        freeze
      end
      private :initialize_stamp

      # True when the three contract blocks parsed into value objects.
      def complete?
        !identity.nil? && !capacity.nil? && !decision.nil?
      end

      # True when the model emitted at least one recognizable envelope piece,
      # including an empty heading: that is a missing block, not no envelope.
      def present?
        identity_present? || capacity_present? || decision_present? || body_present?
      end

      def empty?
        !present?
      end

      def body_present?
        @body_present
      end

      def to_h
        {
          'identity' => identity_fields,
          'capacities' => capacity_fields,
          'decision' => decision_fields,
          'body' => body,
          'body_present' => body_present?,
          'complete' => complete?
        }
      end

      def inspect
        "#<#{self.class.name} complete=#{complete?} identity=#{identity&.agent_id.inspect} " \
          "status=#{decision_fields['status'].inspect}>"
      end

      private

      def parse_json_object(text)
        stripped = text.strip
        return false unless stripped.start_with?('{') && stripped.end_with?('}')

        data = Runes::Json.parse(stripped)
        return false unless data.is_a?(Hash)

        hash = downcase_keys(data)
        return false unless json_envelope?(hash)

        @identity_present = hash.key?('identity')
        @capacity_present = hash.key?('capacities') || hash.key?('capacity')
        @decision_present = hash.key?('decision')
        @identity_fields = normalize_identity_hash(hash['identity'])
        @capacity_fields = normalize_capacity_hash(hash['capacities'] || hash['capacity'] || {})
        @decision_fields = normalize_decision_hash(hash['decision'] || {})
        @body = normalize_body(hash['body'])
        @body_present = hash.key?('body')
        build_objects
        true
      rescue Runes::Json::ParseError
        false
      end

      def json_envelope?(hash)
        hash.key?('identity') && hash.key?('decision') &&
          (hash.key?('capacities') || hash.key?('capacity'))
      end

      def parse_sections(text)
        offset = body_heading_offset(text)
        if offset
          @body_present = true
          @body = text[offset..].to_s.strip
          prefix = text[0...offset]
        else
          prefix = text
        end

        parsed = Runes::Core::SectionParser.new.parse(prefix)
        sections = parsed[:sections] || {}
        @identity_present = sections.key?('IDENTITY')
        @capacity_present = sections.key?('CAPACITIES') || sections.key?('CAPACITY')
        @decision_present = sections.key?('DECISION')
        @identity_fields = normalize_identity_hash(parse_kv(sections['IDENTITY']))
        @capacity_fields = normalize_capacity_hash(parse_kv(sections['CAPACITIES'] || sections['CAPACITY']))
        @decision_fields = normalize_decision_hash(parse_kv(sections['DECISION']))
        build_objects
      end

      # BODY is last. Taking everything after the heading keeps a body that
      # itself contains Markdown headings from being parsed as new sections.
      def body_heading_offset(text)
        offset = 0
        text.each_line do |line|
          return offset + line.length if heading_name(line.strip) == 'BODY'

          offset += line.length
        end
        nil
      end

      def heading_name(line)
        match = line.match(Runes::Core::SectionParser::HEADING)
        return nil if match.nil?

        raw = match[1] || match[2] || match[3]
        return nil if raw.nil?

        normalized = raw.to_s.upcase.gsub(/[^A-Z0-9_]+/, '_').sub(/\A_+/, '').sub(/_+\z/, '')
        normalized.empty? ? nil : normalized
      end

      def parse_kv(text)
        fields = {}
        text.to_s.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')

          match = stripped.match(KV)
          next if match.nil?

          fields[match[1].downcase] = unquote(match[2])
        end
        fields
      end

      def normalize_identity_hash(value)
        return {}.freeze unless value.is_a?(Hash)

        hash = downcase_keys(value)
        out = {}
        IDENTITY_KEYS.each do |key|
          next unless hash.key?(key)

          raw = hash[key]
          out[key] = key == 'adapter_sha256' ? nullish_to_nil(raw) : string_value(raw)
        end
        out.freeze
      end

      def normalize_capacity_hash(value)
        return {}.freeze unless value.is_a?(Hash)

        hash = downcase_keys(value)
        out = {}
        out['can'] = capability_list(hash['can']) if hash.key?('can')
        out['cannot'] = capability_list(hash['cannot']) if hash.key?('cannot')
        if hash.key?('max_input_tokens')
          out['max_input_tokens'] = integer_or_nil(hash['max_input_tokens'])
        end
        if hash.key?('max_output_tokens')
          out['max_output_tokens'] = integer_or_nil(hash['max_output_tokens'])
        end
        out['output_schema'] = string_value(hash['output_schema']) if hash.key?('output_schema')
        out.freeze
      end

      def normalize_decision_hash(value)
        return {}.freeze unless value.is_a?(Hash)

        hash = downcase_keys(value)
        out = {}
        out['status'] = string_value(hash['status'])&.downcase if hash.key?('status')
        reason = hash.key?('reason_code') ? hash['reason_code'] : hash['reason']
        # Models write N/A / none / null for "no reason"; that is :ok.
        reason_text = string_value(reason)&.downcase
        reason_text = 'ok' if reason_text&.match?(/\A(n\/?a|none|null|-|)\z/)
        out['reason_code'] = reason_text unless reason.nil?
        hop = hash.key?('next_hop') ? hash['next_hop'] : hash['next']
        out['next_hop'] = nullish_to_nil(hop)&.downcase unless hop.nil?
        out['message'] = string_value(hash['message']) if hash.key?('message')
        out.freeze
      end

      def normalize_body(value)
        value.nil? ? '' : value.to_s.strip
      end

      def build_objects
        @identity = build_identity
        @capacity = build_capacity
        @decision = build_decision
      end

      def build_identity
        return nil if identity_fields.empty?
        return nil unless (IDENTITY_REQUIRED - identity_fields.keys).empty?

        Identity.from_h(identity_fields)
      rescue Identity::Invalid => e
        @identity_error = e.message
        nil
      end

      def build_capacity
        return nil if capacity_fields.empty?
        return nil unless (CAPACITY_REQUIRED - capacity_fields.keys).empty?

        Capacity.from_h(capacity_fields)
      rescue Capacity::Invalid => e
        @capacity_error = e.message
        nil
      end

      def build_decision
        return nil if decision_fields.empty?
        return nil unless decision_fields.key?('status') && decision_fields.key?('reason_code')

        status = decision_fields['status']
        body = status == 'accept' ? body_text : nil
        Decision.new(
          status: status,
          reason_code: decision_fields['reason_code'],
          next_hop: decision_fields['next_hop'],
          message: decision_fields['message'],
          body: body
        )
      rescue Decision::Invalid => e
        @decision_error = e.message
        nil
      end

      def body_text
        @body
      end

      def downcase_keys(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s.downcase] = value }
      end

      def capability_list(value)
        entries = if value.is_a?(Array)
                    value
                  else
                    value.to_s.sub(/\A\s*[\[{]/, '').sub(/[\]}]\s*\z/, '').split(/[,;\n]/)
                  end
        entries.map { |entry| unquote(entry.to_s).strip }
               .reject(&:empty?)
               .map(&:downcase)
               .uniq
               .freeze
      end

      def integer_or_nil(value)
        return value if value.is_a?(Integer)
        return nil unless value.to_s.strip.match?(/\A\d+\z/)

        value.to_s.strip.to_i
      end

      def string_value(value)
        return nil if value.nil?

        unquote(value.to_s).strip
      end

      def nullish_to_nil(value)
        text = string_value(value)
        return nil if text.nil? || text.empty? || NULLISH.include?(text.downcase)

        text
      end

      def unquote(value)
        value.to_s.strip.sub(QUOTES, '').sub(QUOTES, '')
      end
    end
  end
end
