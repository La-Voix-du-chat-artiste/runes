# frozen_string_literal: true

require_relative '../json_facade'
require_relative '../swarm/model_family'
require_relative '../swarm/identity'
require_relative '../swarm/capacity'
require_relative 'lfm3_adapter'

module Runes
  module LLM
    # The prompt/decoding profile for one text role.
    #
    # A profile is deliberately not a planner and not a transcript. It renders
    # exactly one micro-task, the assigned identity and capacity blocks, and
    # one output contract. The conductor chooses the role; the model never
    # chooses its own identity or a second step.
    class RoleProfile
      ENVELOPE_MODES = %i[echo stamp].freeze

      attr_reader :role, :instructions, :max_tokens, :sampler, :tools,
                  :envelope_mode, :identity, :capacity, :manifest

      def initialize(role:, instructions: nil, max_tokens: nil, sampler: nil,
                     tools: [], envelope_mode: nil, adapter: nil,
                     adapter_sha256: nil, manifest: nil, identity: nil,
                     capacity: nil)
        @role = role.to_s.to_sym
        @manifest = manifest
        @identity = identity || manifest&.identity || default_identity(adapter, adapter_sha256)
        @capacity = capacity || manifest&.capacity || default_capacity(max_tokens)
        @instructions = instructions.nil? ? nil : instructions.to_s
        @max_tokens = max_tokens.nil? ? @capacity.max_output_tokens : integer!(max_tokens)
        @sampler = sampler
        @tools = @role == :scout ? Array(tools).map(&:to_s) : []
        @envelope_mode = (envelope_mode ||
                          manifest&.family&.envelope_mode ||
                          default_envelope_mode).to_s.to_sym
        unless ENVELOPE_MODES.include?(@envelope_mode)
          raise ArgumentError,
                "role profile: envelope_mode must be :echo or :stamp, got #{envelope_mode.inspect}"
        end
      end

      # Build from a manifest, which is the common conductor path.
      def self.for(manifest, instructions: nil, max_tokens: nil, sampler: nil,
                   tools: [], envelope_mode: nil, adapter: nil,
                   adapter_sha256: nil)
        new(
          role: manifest.role,
          instructions: instructions,
          max_tokens: max_tokens,
          sampler: sampler,
          tools: tools,
          envelope_mode: envelope_mode,
          adapter: adapter,
          adapter_sha256: adapter_sha256,
          manifest: manifest
        )
      end

      def echo?
        @envelope_mode == :echo
      end

      def stamp?
        @envelope_mode == :stamp
      end

      def schema
        @capacity.output_schema
      end

      # Render one prompt. `manifest:` may override the constructor's
      # manifest, because the conductor resolves a role immediately before
      # the call. Evidence and perception are rendered as data, never as a
      # multi-step instruction.
      def prompt(task: nil, evidence: nil, media: nil, perception: nil,
                 manifest: nil, packet: nil, question: nil, **extra)
        assigned = manifest || @manifest
        identity_block = assigned&.identity || @identity
        capacity_block = assigned&.capacity || @capacity
        task = question if task.nil? && !question.nil?
        evidence = packet if evidence.nil? && !packet.nil?

        blocks = []
        blocks << identity_section(identity_block)
        blocks << capacity_section(capacity_block)
        blocks << contract_section(capacity_block.output_schema)
        blocks << instructions_section unless @instructions.to_s.strip.empty?
        blocks << tools_section unless @tools.empty?
        blocks << "### TASK\n#{task}" unless task.nil? || task.to_s.strip.empty?
        blocks << "### EVIDENCE\n#{render_packet(evidence)}" unless evidence.nil?
        blocks << "### PERCEPTION\n#{render_packet(perception)}" unless perception.nil?
        blocks << media_section(media) unless media.nil?
        extra.each do |key, value|
          next if value.nil?

          blocks << "### #{key.to_s.upcase}\n#{render_packet(value)}"
        end
        blocks.join("\n\n") + "\n"
      end

      def to_h
        {
          'role' => @role.to_s,
          'agent_id' => @identity.agent_id,
          'version' => @identity.version,
          'adapter' => @identity.adapter,
          'adapter_sha256' => @identity.adapter_sha256,
          'max_tokens' => @max_tokens,
          'sampler' => @sampler,
          'tools' => @tools,
          'envelope_mode' => @envelope_mode.to_s,
          'output_schema' => schema
        }
      end

      def inspect
        "#<#{self.class.name} role=#{@role} agent=#{@identity.agent_id} mode=#{@envelope_mode}>"
      end

      private

      def identity_section(identity)
        fields = identity.to_h
        lines = ['### IDENTITY']
        Runes::Swarm::Identity::FIELDS.each do |key|
          value = fields[key]
          lines << "#{key}: #{value.nil? ? 'null' : value}"
        end
        lines.join("\n")
      end

      def capacity_section(capacity)
        fields = capacity.to_h
        [
          '### CAPACITIES',
          "can: #{fields['can'].join(', ')}",
          "cannot: #{fields['cannot'].join(', ')}",
          "max_input_tokens: #{fields['max_input_tokens']}",
          "max_output_tokens: #{fields['max_output_tokens']}",
          "output_schema: #{fields['output_schema']}"
        ].join("\n")
      end

      def contract_section(output_schema)
        if echo?
          <<~CONTRACT.strip
            ### OUTPUT CONTRACT
            Your identity and capacities are assigned by the adapter — do not
            echo them. Return exactly two blocks, in this order:

            ### DECISION
            status: accept | decline | escalate
            reason_code: ok
            next_hop: null
            message: <one sentence, no facts>

            For decline or escalate, replace `ok` with one typed reason (for
            example out_of_scope or missing_evidence) and leave BODY empty.

            ### BODY
            <the task result, or an empty body for decline/escalate>

            If the task is outside the assigned capacities, return
            `status: decline` with a reason code and an empty body. Do not use
            tools unless they are listed below. Do not plan more than this one
            micro-task. No other text, no fences.
          CONTRACT
        else
          <<~CONTRACT.strip
            ### OUTPUT CONTRACT
            This is a stamp-mode role: return only the typed #{output_schema} artifact
            requested below. Do not emit an IDENTITY, CAPACITIES or DECISION
            block; the adapter stamps the assigned envelope.

            If the task is outside these capacities, return a declined
            #{output_schema} artifact with a typed reason code and no prose.
          CONTRACT
        end
      end

      def instructions_section
        "### INSTRUCTIONS\n#{@instructions}"
      end

      def tools_section
        lines = ['### TOOLS', 'You may use only these tools:']
        @tools.each { |tool| lines << "- #{tool}" }
        lines.join("\n")
      end

      def media_section(media)
        entries = Array(media)
        lines = ['### MEDIA']
        entries.each do |entry|
          if entry.is_a?(Hash)
            hash = entry.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
            path = hash['path'] || hash['file'] || hash['input']
            modality = hash['modality']
            lines << "- #{path}#{modality ? " (#{modality})" : ''}"
          else
            lines << "- #{entry}"
          end
        end
        lines.join("\n")
      end

      def render_packet(value)
        case value
        when Hash, Array
          Runes::Json.generate(value)
        else
          value.to_s
        end
      end

      def default_identity(adapter, adapter_sha256)
        family = Runes::Swarm::ModelFamily.models_for(@role).first
        Runes::Swarm::Identity.new(
          agent_id: "#{@role}.profile",
          version: '1.0.0',
          role: @role,
          base_model: family,
          adapter: adapter.to_s.empty? ? "prompt:#{@role}-v1" : adapter.to_s,
          adapter_sha256: adapter_sha256
        )
      end

      def default_capacity(max_tokens)
        family = Runes::Swarm::ModelFamily.fetch(Runes::Swarm::ModelFamily.models_for(@role).first)
        budget = max_tokens.nil? ? 320 : integer!(max_tokens)
        Runes::Swarm::Capacity.new(
          can: default_can,
          cannot: default_cannot,
          max_input_tokens: family.context_tokens,
          max_output_tokens: budget,
          output_schema: Runes::Swarm::ModelFamily.schema_for(@role)
        )
      end

      def default_can
        case @role
        when :scout then %w[retrieve execute_tools cite_sources decline]
        when :critic then %w[read_evidence audit_claims list_unsupported cite decline]
        when :verifier then %w[check_citations check_contract decline]
        when :planner then %w[decompose select_shape define_acceptance decline]
        when :reviewer then %w[inspect_tests write_review issue_repair decline]
        when :ideator then %w[read_evidence propose_direct cite decline]
        when :escalation then %w[answer reason human_review decline]
        else %w[read_evidence answer_fr answer_en cite abstain decline]
        end
      end

      def default_cannot
        %w[retrieve execute_tools write_code verify_own_citations critique rewrite] - default_can
      end

      def integer!(value)
        unless value.is_a?(Integer) && !value.negative?
          raise ArgumentError,
                "role profile: max_tokens must be a non-negative Integer, got #{value.inspect}"
        end

        value
      end

      def default_envelope_mode
        Runes::Swarm::ModelFamily.fetch(Runes::Swarm::ModelFamily.models_for(@role).first).envelope_mode
      rescue Runes::Swarm::ModelFamily::Invalid
        :echo
      end
    end
  end
end
