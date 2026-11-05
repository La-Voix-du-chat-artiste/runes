# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

module Runes
  module Bench
    module Swarm
      # Load and validate the tracked 24-case file.
      #
      # A malformed case is a hard error. Silently skipping one would make the
      # denominator lie, and a missing or absolute media path would make the
      # benchmark depend on a developer's checkout.
      class Cases
        class Error < StandardError; end

        FAMILIES = %w[text vision audio audio-video decision out_of_scope].freeze
        MEDIA_MODALITIES = {
          'vision' => %w[image],
          'audio' => %w[audio],
          'audio-video' => %w[video]
        }.freeze
        SHAPES = %w[decide answer-lite answer-full see hear watch escalate].freeze
        DECISIONS = %w[accept decline escalate].freeze
        CHECK_KEYS = %w[must_cite must_match must_not_match field must_abstain].freeze
        MEDIA_EXTENSIONS = {
          'image' => %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif],
          'audio' => %w[.wav .mp3 .m4a .flac .ogg .aac .opus .aiff .aif],
          'video' => %w[.mp4 .mov .mkv .webm .avi .m4v]
        }.freeze

        attr_reader :path, :root, :provenance, :cases

        def self.load(path)
          new(path).tap(&:validate!)
        end

        def initialize(path)
          @path = File.expand_path(path.to_s)
          @root = File.dirname(@path)
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
            validate_case(id, spec)
          end
          self
        end

        def select(ids)
          return @cases if ids.nil? || ids.empty?

          wanted = Array(ids).map(&:to_s)
          known = @cases.map { |spec| spec['id'].to_s }
          unknown = wanted - known
          raise Error, "unknown case id(s): #{unknown.join(', ')}" unless unknown.empty?

          @cases.select { |spec| wanted.include?(spec['id'].to_s) }
        end

        def by_family
          @cases.group_by { |spec| spec['family'].to_s }
        end

        def families
          FAMILIES.select { |family| @cases.any? { |spec| spec['family'].to_s == family } }
        end

        def total_checks
          @cases.sum { |spec| check_count(spec['checks']) }
        end

        def check_count(checks)
          return 0 unless checks.is_a?(Hash)

          CHECK_KEYS.sum { |key| Array(checks[key]).size }
        end

        def file_sha256
          Digest::SHA256.file(@path).hexdigest
        end

        # Media paths are relative to bench/swarm/ and must resolve inside it.
        def media_path(relative)
          value = relative.to_s
          raise Error, "#{@path}: media path must be relative, got #{value.inspect}" if Pathname.new(value).absolute?

          expanded = File.expand_path(value, @root)
          unless expanded.start_with?(@root + File::SEPARATOR) || expanded == @root
            raise Error, "#{@path}: media path escapes bench/swarm: #{value.inspect}"
          end
          raise Error, "#{@path}: media file not found: #{value}" unless File.file?(expanded)

          expanded
        end

        def media_modality(relative)
          extension = File.extname(relative.to_s).downcase
          MEDIA_EXTENSIONS.each do |modality, extensions|
            return modality if extensions.include?(extension)
          end
          raise Error, "#{@path}: unknown media extension #{extension.inspect} for #{relative.inspect}"
        end

        private

        def validate_case(id, spec)
          family = spec['family'].to_s
          unless FAMILIES.include?(family)
            raise Error, "#{@path}: #{id} has unknown family #{family.inspect}"
          end

          question = spec['question']
          unless question.is_a?(String) && !question.strip.empty?
            raise Error, "#{@path}: #{id} has no question"
          end

          validate_evidence(id, spec)
          validate_media(id, spec, family)
          validate_gold(id, spec)
          validate_checks(id, 'checks', spec['checks'])
          validate_checks(id, 'perception_checks', spec['perception_checks']) if spec.key?('perception_checks')
          validate_questions(id, spec)

          decision = (spec['expected_decision'] || 'accept').to_s
          unless DECISIONS.include?(decision)
            raise Error, "#{@path}: #{id} has unknown expected_decision #{decision.inspect}"
          end

          if decision != 'accept' && spec['expected_reason'].to_s.strip.empty?
            raise Error, "#{@path}: #{id} is a #{decision} case and must name expected_reason"
          end

          shape = spec['expected_shape']
          unless shape.nil? || SHAPES.include?(shape.to_s)
            raise Error, "#{@path}: #{id} has unknown expected_shape #{shape.inspect}"
          end

          validate_string_array(id, 'forbidden_roles', spec['forbidden_roles'])
          validate_string_array(id, 'tags', spec['tags'])
          validate_hash(id, 'task_profile', spec['task_profile'])

          return if check_count(spec['checks']).positive? || decision != 'accept'
          return if spec['questions'].is_a?(Array) && !spec['questions'].empty?

          raise Error, "#{@path}: #{id} has no mechanical check and no typed question"
        end

        def validate_evidence(id, spec)
          evidence = spec['evidence']
          raise Error, "#{@path}: #{id} has no evidence array" unless evidence.is_a?(Array)

          evidence.each_with_index do |entry, index|
            unless entry.is_a?(Hash)
              raise Error, "#{@path}: #{id}.evidence[#{index}] is not an object"
            end
            unless entry['citation'].is_a?(String) && !entry['citation'].strip.empty?
              raise Error, "#{@path}: #{id}.evidence[#{index}] has no citation"
            end
            unless entry['text'].is_a?(String) && !entry['text'].strip.empty?
              raise Error, "#{@path}: #{id}.evidence[#{index}] has no text"
            end
          end
        end

        def validate_media(id, spec, family)
          media = spec['media']
          raise Error, "#{@path}: #{id} has no media array" unless media.is_a?(Array)

          media.each do |entry|
            raise Error, "#{@path}: #{id} media entry must be a string" unless entry.is_a?(String)

            absolute = media_path(entry)
            modality = media_modality(entry)
            allowed = MEDIA_MODALITIES[family]
            next if allowed.nil? && media.empty?
            next if allowed && allowed.include?(modality)

            raise Error,
                  "#{@path}: #{id} is a #{family} case but #{entry.inspect} is #{modality}"
          end
        end

        def validate_gold(id, spec)
          gold = spec['gold']
          raise Error, "#{@path}: #{id} has no gold object" unless gold.is_a?(Hash)
        end

        def validate_checks(id, name, checks)
          return if checks.nil?

          raise Error, "#{@path}: #{id}.#{name} must be an object" unless checks.is_a?(Hash)

          unknown = checks.keys.map(&:to_s) - CHECK_KEYS
          unless unknown.empty?
            raise Error, "#{@path}: #{id}.#{name} has unknown keys #{unknown.sort.inspect}"
          end

          CHECK_KEYS.each do |key|
            value = checks[key]
            next if value.nil?

            case key
            when 'field'
              unless value.is_a?(String) && !value.strip.empty?
                raise Error, "#{@path}: #{id}.#{name}.field must be a string"
              end
            when 'must_abstain'
              unless [true, false].include?(value)
                raise Error, "#{@path}: #{id}.#{name}.must_abstain must be boolean"
              end
            else
              raise Error, "#{@path}: #{id}.#{name}.#{key} must be an array" unless value.is_a?(Array)

              value.each do |pattern|
                raise Error, "#{@path}: #{id}.#{name}.#{key} contains a non-string" unless pattern.is_a?(String)
              end
              value.each { |pattern| validate_regex(id, "#{name}.#{key}", pattern) } if key != 'must_cite'
            end
          end
        end

        def validate_questions(id, spec)
          questions = spec['questions']
          return if questions.nil?

          raise Error, "#{@path}: #{id}.questions must be an array" unless questions.is_a?(Array)

          questions.each_with_index do |question, index|
            unless question.is_a?(Hash)
              raise Error, "#{@path}: #{id}.questions[#{index}] is not an object"
            end
            unless question['id'].is_a?(String) && !question['id'].strip.empty?
              raise Error, "#{@path}: #{id}.questions[#{index}] has no id"
            end
            unless question['question'].is_a?(String) && !question['question'].strip.empty?
              raise Error, "#{@path}: #{id}.questions[#{index}] has no question"
            end
          end
        end

        def validate_regex(id, key, pattern)
          Regexp.new(pattern.to_s, Regexp::IGNORECASE)
        rescue RegexpError => e
          raise Error, "#{@path}: #{id}.#{key} has invalid regex #{pattern.inspect}: #{e.message}"
        end

        def validate_string_array(id, key, value)
          return if value.nil?

          raise Error, "#{@path}: #{id}.#{key} must be an array" unless value.is_a?(Array)
          return if value.all? { |entry| entry.is_a?(String) }

          raise Error, "#{@path}: #{id}.#{key} contains a non-string"
        end

        def validate_hash(id, key, value)
          return if value.nil? || value.is_a?(Hash)

          raise Error, "#{@path}: #{id}.#{key} must be an object"
        end
      end
    end
  end
end
