# frozen_string_literal: true

require 'json'

module Runes
  module Bench
    module Cumulative
      # Load and validate the tracked case file. A malformed case is a hard
      # error: silently skipping it would make a denominator lie.
      class Cases
        class Error < StandardError; end

        CHECK_KEYS = %w[must_cite must_match must_not_match].freeze

        attr_reader :path, :provenance, :cases

        def self.load(path)
          new(path).tap(&:validate!)
        end

        def initialize(path)
          @path = path.to_s
          data = JSON.parse(File.read(@path))
          @provenance = data.is_a?(Hash) ? (data['provenance'] || {}) : {}
          @cases = data.is_a?(Hash) ? data['cases'] : data
          raise Error, "#{@path}: expected a cases array" unless @cases.is_a?(Array)
        rescue JSON::ParserError => e
          raise Error, "#{@path}: invalid JSON: #{e.message}"
        rescue Errno::ENOENT
          raise Error, "#{@path}: case file not found"
        end

        def validate!
          ids = {}
          @cases.each_with_index do |spec, index|
            unless spec.is_a?(Hash)
              raise Error, "#{@path}: case #{index} is not an object"
            end

            id = spec['id'].to_s
            raise Error, "#{@path}: case #{index} has no id" if id.empty?
            raise Error, "#{@path}: duplicate case id #{id.inspect}" if ids.key?(id)

            ids[id] = true
            raise Error, "#{@path}: #{id} has no question" unless spec['question'].is_a?(String)
            raise Error, "#{@path}: #{id} has no evidence array" unless spec['evidence'].is_a?(Array)
            raise Error, "#{@path}: #{id} has no checks object" unless spec['checks'].is_a?(Hash)

            validate_checks(id, spec['checks'])
          end
          self
        rescue JSON::ParserError => e
          raise Error, "#{@path}: invalid JSON: #{e.message}"
        end

        def select(ids)
          return @cases if ids.nil? || ids.empty?

          wanted = Array(ids).map(&:to_s)
          unknown = wanted - @cases.map { |spec| spec['id'].to_s }
          raise Error, "unknown case id(s): #{unknown.join(', ')}" unless unknown.empty?

          @cases.select { |spec| wanted.include?(spec['id'].to_s) }
        end

        def total_checks
          @cases.sum { |spec| check_count(spec['checks']) }
        end

        def check_count(checks)
          CHECK_KEYS.sum { |key| Array(checks[key]).size }
        end

        private

        def validate_checks(id, checks)
          CHECK_KEYS.each do |key|
            value = checks[key]
            next if value.nil?

            raise Error, "#{@path}: #{id}.#{key} must be an array" unless value.is_a?(Array)

            value.each do |entry|
              next if entry.is_a?(String)

              raise Error, "#{@path}: #{id}.#{key} contains a non-string"
            end
          end

          Array(checks['must_match']).each { |pattern| validate_regex(id, 'must_match', pattern) }
          Array(checks['must_not_match']).each { |pattern| validate_regex(id, 'must_not_match', pattern) }
        end

        def validate_regex(id, key, pattern)
          Regexp.new(pattern.to_s, Regexp::IGNORECASE)
        rescue RegexpError => e
          raise Error, "#{@path}: #{id}.#{key} has invalid regex #{pattern.inspect}: #{e.message}"
        end
      end
    end
  end
end
