# frozen_string_literal: true

require 'digest'

require_relative '../../lib/runes'

module Runes
  module Bench
    module Swarm
      # Scripted models for the Phase 6 harness tests.
      #
      # The fakes close over the case, so a "perfect" model can return the
      # gold label. They are deliberately not used by the benchmark itself;
      # they prove the runner, grading and report without a checkpoint, a GPU
      # or a network call.
      module Fakes
        module_function

        def factory
          lambda do |manifest, spec:, arm:, seed:|
            case manifest.role.to_sym
            when :triage, :judge
              D1.new(spec, manifest)
            when :vision, :audio, :omni
              Media.new(spec, manifest)
            else
              Text.new(spec, manifest)
            end
          end
        end

        class Base
          def initialize(spec, manifest)
            @spec = spec
            @manifest = manifest
          end

          def available?
            true
          end

          def availability_error
            nil
          end

          def model_name
            @manifest.base_model
          end
        end

        class D1 < Base
          def system_one(state, questions, media: nil, role: nil, manifest: nil)
            _ = state
            _ = media
            target = manifest || @manifest
            answers, status, reason = answers_for(questions, target)
            decision = Runes::Swarm::Decision.new(
              status: status,
              reason_code: reason,
              body: status == :accept ? 'typed decision' : ''
            )
            artifact = {
              'schema' => target.capacity.output_schema,
              'answers' => answers,
              'decision' => {
                'status' => status.to_s,
                'reason_code' => reason.to_s,
                'message' => 'scripted'
              }
            }
            envelope = Runes::Swarm::Envelope.stamp(
              manifest: target, decision: decision, body: decision.body
            )
            {
              ok: true, content: Runes::Json.generate(artifact), usage: nil,
              finish_reason: nil, status: :ok, error: nil,
              artifact: artifact, answers: answers, decision: decision,
              envelope: envelope, family: target.base_model, modalities: ['text']
            }
          end

          def call(state, questions = [], **kwargs)
            system_one(state, questions, **kwargs)
          end

          private

          def answers_for(questions, _target)
            ids = Array(questions).map { |question| (question['id'] || question[:id]).to_s }
            if @manifest.role.to_sym == :triage
              triage_answers
            elsif ids.include?('support_a')
              select_answers
            elsif ids.include?('support')
              review_answers(ids)
            else
              decision_answers(ids)
            end
          end

          def triage_answers
            answers = [
              answer('modality', modality, 0.95),
              answer('intent', @spec.dig('task_profile', 'intent') || 'answer', 0.90),
              answer('scope', in_scope? ? 0.95 : 0.05, in_scope? ? 0.95 : 0.05),
              answer('shape', @spec['expected_shape'] || 'answer-lite', 0.90)
            ]
            if @spec['expected_reason'].to_s == 'out_of_scope'
              [answers, :decline, :out_of_scope]
            else
              [answers, :accept, :ok]
            end
          end

          def select_answers
            [
              [answer('support_a', 0.90, 0.90), answer('support_b', 0.70, 0.70),
               answer('choice', 'a', 0.90)],
              :accept, :ok
            ]
          end

          def review_answers(ids)
            answers = ids.map do |id|
              value = case id
                      when 'contradiction' then 0.02
                      else 0.95
                      end
              answer(id, value, value)
            end
            [answers, :accept, :ok]
          end

          def decision_answers(ids)
            label = @spec.dig('gold', 'label') || @spec.dig('gold', 'answer') || 'ok'
            answers = ids.map { |id| answer(id, label, 0.95) }
            [answers, :accept, :ok]
          end

          def answer(id, value, probability)
            { 'id' => id, 'value' => value, 'probability' => probability }
          end

          def modality
            case @spec['family'].to_s
            when 'vision' then 'image'
            when 'audio' then 'audio'
            when 'audio-video' then 'video'
            else 'text'
            end
          end

          def in_scope?
            @spec['expected_reason'].to_s != 'out_of_scope'
          end
        end

        class Text < Base
          def call(prompt, role: nil, max_tokens: nil)
            _ = prompt
            _ = role
            _ = max_tokens
            status, reason = decision
            body = status == :accept ? body_for : ''
            {
              ok: true,
              content: envelope(status, reason, body),
              usage: nil, finish_reason: nil, status: :ok, error: nil
            }
          end

          private

          def decision
            return [:decline, @spec['expected_reason'].to_sym] if decline_role? &&
                                                                 @spec['expected_reason']

            [:accept, :ok]
          end

          def decline_role?
            %i[answerer repairer generalist].include?(@manifest.role.to_sym) &&
              @spec['expected_decision'].to_s == 'decline'
          end

          def body_for
            case @manifest.role.to_sym
            when :ideator
              @manifest.agent_id.end_with?('.alternative') ?
                'Proposal B: a genuinely different route.' :
                'Proposal A: the most direct route.'
            when :critic
              "### NON_SOUTENU\n- aucune"
            else
              answer_body
            end
          end

          def answer_body
            gold = @spec['gold'] || {}
            text = gold['answer'] || gold['label'] || gold['reason'] || 'non documenté'
            cites = Array(@spec.dig('checks', 'must_cite'))
            cites = Array(gold['anchors']) if cites.empty?
            cites.empty? ? text.to_s : "#{text}\nCitations: #{cites.join(', ')}"
          end

          def envelope(status, reason, body)
            identity = @manifest.identity.to_h
            capacity = @manifest.capacity.to_h
            <<~TEXT
              ### IDENTITY
              agent_id: #{identity['agent_id']}
              version: #{identity['version']}
              role: #{identity['role']}
              base_model: #{identity['base_model']}
              adapter: #{identity['adapter']}
              adapter_sha256: #{identity['adapter_sha256'] || 'null'}

              ### CAPACITIES
              can: #{capacity['can'].join(', ')}
              cannot: #{capacity['cannot'].join(', ')}
              max_input_tokens: #{capacity['max_input_tokens']}
              max_output_tokens: #{capacity['max_output_tokens']}
              output_schema: #{capacity['output_schema']}

              ### DECISION
              status: #{status}
              reason_code: #{reason}
              next_hop: null
              message: scripted

              ### BODY
              #{body}
            TEXT
          end
        end

        class Media < Base
          def call(input = nil, media: nil, role: nil, manifest: nil)
            _ = role
            target = manifest || @manifest
            path = input || media
            path = path['path'] if path.is_a?(Hash)
            digest = Digest::SHA256.file(path.to_s).hexdigest
            modality = modality_for
            anchors = Array(@spec.dig('gold', 'anchors'))
            anchors = [default_anchor(modality)] if anchors.empty?
            content = perception_text
            artifact = {
              'schema' => 'perception.v1',
              'modality' => modality.to_s,
              'source_sha256' => digest,
              'anchors' => anchors,
              'body' => content
            }
            decision = Runes::Swarm::Decision.new(status: :accept, reason_code: :ok, body: content)
            envelope = Runes::Swarm::Envelope.stamp(
              manifest: target, decision: decision, body: content
            )
            {
              ok: true, content: content, usage: nil, finish_reason: nil,
              status: :ok, error: nil, artifact: artifact, anchors: anchors,
              source_sha256: digest, decision: decision, envelope: envelope,
              family: target.base_model, modalities: [modality.to_s]
            }
          end

          private

          def modality_for
            case @spec['family'].to_s
            when 'vision' then :image
            when 'audio' then :audio
            else :video
            end
          end

          def default_anchor(modality)
            modality == :image ? 'image:1' : 'time:0'
          end

          def perception_text
            gold = @spec['gold'] || {}
            if @spec['expected_reason'].to_s == 'conflicting_evidence'
              return 'contradiction: the speech and the image disagree; the circle is red.'
            end

            gold['answer'] || gold['speech'] || gold['visual'] || 'perception'
          end
        end
      end
    end
  end
end
