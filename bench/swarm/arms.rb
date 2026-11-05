# frozen_string_literal: true

module Runes
  module Bench
    module Swarm
      # The benchmark arms.
      #
      # A conductor arm is the contracted team. A solo arm is a one-call
      # baseline. The legacy control reuses `Runes::Orchestration::Cumulative`
      # and is never a candidate. Every definition names the roles it may use,
      # so a test can prove an arm did not silently grow a generalist.
      module Arms
        class Error < StandardError; end

        DEFINITIONS = {
          'solo-1.7B' => {
            kind: :solo,
            shape: 'answer-lite',
            roles: %w[generalist],
            model: 'LiquidAI/LFM3-1.7B',
            description: 'one text call; text baseline'
          },
          'solo-VL' => {
            kind: :solo_media,
            shape: 'see',
            roles: %w[vision],
            model: 'LiquidAI/LFM3-VL-2B',
            description: 'one VL call; vision baseline'
          },
          'solo-Audio' => {
            kind: :solo_media,
            shape: 'hear',
            roles: %w[audio],
            model: 'LiquidAI/LFM3-Audio-2B',
            description: 'one Audio call; audio baseline'
          },
          'solo-Omni' => {
            kind: :solo_media,
            shape: 'watch',
            roles: %w[omni],
            model: 'LiquidAI/LFM3-Omni-2B',
            description: 'one Omni call; audio-video baseline'
          },
          'd1-only' => {
            kind: :conductor,
            shape: 'decide',
            roles: %w[triage judge reviewer verifier],
            finalize: false,
            description: 'triage -> typed decision -> verifier; decision baseline'
          },
          'text-lite' => {
            kind: :conductor,
            shape: 'answer-lite',
            roles: %w[answerer judge reviewer verifier],
            finalize: false,
            description: 'answerer + d1 judge + verifier; cheap text team'
          },
          'text-full' => {
            kind: :conductor,
            shape: 'answer-full',
            roles: %w[ideator judge answerer critic reviewer verifier repairer],
            finalize: false,
            description: 'ideate A||B -> judge -> answerer -> critic -> judge -> repair'
          },
          'perception+text-lite' => {
            kind: :conductor,
            shape: :perception,
            roles: %w[vision audio omni answerer judge reviewer verifier],
            finalize: false,
            description: 'VL/Audio/Omni -> text-lite; modality lift'
          },
          'team-full' => {
            kind: :conductor,
            shape: nil,
            roles: :all,
            finalize: true,
            description: 'shape router + all roles; the candidate'
          },
          'frontier-1x' => {
            kind: :frontier,
            shape: 'answer-lite',
            roles: %w[escalation],
            description: 'external reference; gap measurement only'
          },
          'same-model-3x' => {
            kind: :legacy,
            shape: 'answer-full',
            roles: %w[generalist],
            max_calls: 3,
            description: 'legacy 1.7B answer -> critic -> repair; control only'
          },
          'profile-only' => {
            kind: :conductor,
            shape: 'answer-lite',
            roles: %w[answerer judge reviewer verifier],
            finalize: false,
            adapter: false,
            description: 'text roles without LoRA; specialization honesty'
          },
          'adapter' => {
            kind: :conductor,
            shape: 'answer-lite',
            roles: %w[answerer judge reviewer verifier],
            finalize: false,
            adapter: true,
            description: 'text roles with LoRA; specialization honesty'
          }
        }.freeze

        NAMES = DEFINITIONS.keys.freeze

        # A solo baseline is only meaningful on its own family. `team-full` and
        # `frontier-1x` may attempt every case. The decision baselines run the
        # decision and out-of-scope families only.
        APPLICABLE_FAMILIES = {
          'solo-1.7B' => %w[text decision out_of_scope],
          'solo-VL' => %w[vision],
          'solo-Audio' => %w[audio],
          'solo-Omni' => %w[audio-video],
          'd1-only' => %w[decision out_of_scope],
          'text-lite' => %w[text decision out_of_scope],
          'text-full' => %w[text decision out_of_scope],
          'perception+text-lite' => %w[vision audio audio-video],
          'team-full' => nil,
          'frontier-1x' => %w[text decision out_of_scope],
          'same-model-3x' => %w[text decision out_of_scope],
          'profile-only' => %w[text decision out_of_scope],
          'adapter' => %w[text decision out_of_scope]
        }.freeze

        module_function

        def fetch(name)
          key = name.to_s
          definition = DEFINITIONS[key]
          raise Error, "unknown arm #{name.inspect}; choose #{NAMES.join(', ')}" if definition.nil?

          definition.merge(name: key)
        end

        def names
          NAMES.dup
        end

        def applicable?(name, family)
          allowed = APPLICABLE_FAMILIES.fetch(name.to_s) do
            raise Error, "unknown arm #{name.inspect}"
          end
          allowed.nil? || allowed.include?(family.to_s)
        end

        def conductor?(name)
          fetch(name)[:kind] == :conductor
        end

        def media?(name)
          %w[solo-VL solo-Audio solo-Omni perception+text-lite].include?(name.to_s)
        end

        def legacy?(name)
          fetch(name)[:kind] == :legacy
        end

        def roles(name, spec = nil)
          definition = fetch(name)
          return definition[:roles] unless definition[:roles] == :all

          roles = %w[conductor planner triage judge vision audio omni ideator answerer critic
                     repairer finalizer reviewer verifier escalation scout]
          roles << spec['family'].to_s if spec
          roles.uniq
        end

        # The shape a conductor arm is forced to use. `team-full` is nil: the
        # triage verdict must choose it. `perception+text-lite` follows the
        # fixture family.
        def forced_shape(name, spec = nil)
          definition = fetch(name)
          shape = definition[:shape]
          return nil if shape.nil?
          return shape unless shape == :perception
          return nil if spec.nil?

          case spec['family'].to_s
          when 'vision' then 'see'
          when 'audio' then 'hear'
          when 'audio-video' then 'watch'
          else 'see'
          end
        end

        def adapter?(name)
          fetch(name)[:adapter]
        end
      end
    end
  end
end
