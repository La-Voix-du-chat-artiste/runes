# frozen_string_literal: true

require_relative '../compat'
require_relative '../sha256_facade'

module Runes
  # One role call's contract-level receipt.
  #
  # Like `RunReceipt`, this is publishable: it records hashes and sizes, the
  # decision and the status, never the raw prompt or completion.
  class RoleReceipt
    attr_reader :role, :agent_id, :version, :adapter_sha256, :decision, :status,
                :prompt_sha, :prompt_chars, :completion_sha, :completion_chars,
                :elapsed_s, :error, :model_family, :modalities, :calibration,
                :divergence, :repair_round, :cold, :warm

    def initialize(role:, agent_id: nil, version: nil, adapter_sha256: nil,
                   decision: nil, status: :ok, prompt: nil, completion: nil,
                   prompt_sha: nil, prompt_chars: nil, completion_sha: nil,
                   completion_chars: nil, elapsed_s: nil, error: nil,
                   model_family: nil, modalities: nil, calibration: nil,
                   divergence: nil, repair_round: nil, cold: nil, warm: nil)
      @role = role.to_s
      @agent_id = agent_id&.to_s
      @version = version&.to_s
      @adapter_sha256 = adapter_sha256&.to_s
      @decision = normalize_decision(decision)
      @status = status.to_s
      @model_family = model_family&.to_s
      @modalities = normalize_list(modalities)
      @calibration = normalize_decision(calibration)
      @divergence = normalize_decision(divergence)
      @repair_round = repair_round.nil? ? nil : repair_round.to_i
      @cold = cold.nil? ? nil : (cold ? true : false)
      @warm = warm.nil? ? nil : (warm ? true : false)

      prompt_text = prompt.nil? ? nil : prompt.to_s
      completion_text = completion.nil? ? nil : completion.to_s
      @prompt_sha = (prompt_sha || (prompt_text && Runes::SHA256.hex(prompt_text)))&.to_s
      @prompt_chars = prompt_chars || (prompt_text && prompt_text.length)
      @completion_sha = (completion_sha || completion_hash(completion_text))&.to_s
      @completion_chars = completion_chars || (completion_text && completion_text.length)
      @elapsed_s = elapsed_s.nil? ? nil : elapsed_s.to_f.round(3)
      @error = error
      freeze
    end

    def to_h
      {
        'role' => role,
        'agent_id' => agent_id,
        'version' => version,
        'adapter_sha256' => adapter_sha256,
        'decision' => decision,
        'status' => status,
        'prompt_sha' => prompt_sha,
        'prompt_chars' => prompt_chars,
        'completion_sha' => completion_sha,
        'completion_chars' => completion_chars,
        'elapsed_s' => elapsed_s,
        'error' => error,
        'model_family' => model_family,
        'modalities' => modalities,
        'calibration' => calibration,
        'divergence' => divergence,
        'repair_round' => repair_round,
        'cold' => cold,
        'warm' => warm
      }
    end

    def inspect
      "#<#{self.class.name} role=#{role} agent=#{agent_id} status=#{status}>"
    end

    private

    def completion_hash(text)
      return nil if text.nil? || text.empty?

      Runes::SHA256.hex(text)
    end

    def normalize_decision(value)
      return nil if value.nil?

      hash = value.respond_to?(:to_h) ? value.to_h : value
      return nil unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(key, item), out| out[key.to_s] = item }.freeze
    end

    def normalize_list(value)
      return nil if value.nil?

      Array(value).map(&:to_s).freeze
    end
  end

  # Per-call and aggregate receipt for a cumulative run.
  #
  # Raw prompts and answers belong in the ledger, not here: a receipt is safe
  # to publish (prompt hashes and sizes, no secrets) and cheap to aggregate.
  class RunReceipt
    attr_reader :run_id, :model, :sampler, :arm, :case_id, :calls,
                :started_at, :finished_at, :status, :cost_usd, :role_receipts,
                :shape, :calibration, :peak_memory_mb

    def initialize(run_id: nil, model: nil, sampler: {}, arm: nil, case_id: nil,
                   shape: nil, calibration: nil, peak_memory_mb: nil)
      @run_id = run_id
      @model = model
      @sampler = sampler || {}
      @arm = arm
      @case_id = case_id
      @shape = shape&.to_s
      @calibration = calibration
      @peak_memory_mb = peak_memory_mb
      @calls = []
      @role_receipts = []
      @started_at = Runes::Compat.utc_iso8601(Time.now)
      @started_monotonic = Runes::Compat.monotonic
      @finished_at = nil
      @status = nil
      @cost_usd = nil
    end

    def add_call(role:, prompt:, content: nil, elapsed_s: nil, usage: nil,
                 finish_reason: nil, status: :ok, error: nil, model: nil)
      prompt_text = prompt.to_s
      content_text = content.to_s
      call = {
        'role' => role.to_s,
        'model' => (model || @model).to_s,
        'prompt_chars' => prompt_text.length,
        'prompt_sha' => Runes::SHA256.hex(prompt_text),
        'completion_chars' => content_text.length,
        'completion_sha' => content_text.empty? ? nil : Runes::SHA256.hex(content_text),
        'elapsed_s' => elapsed_s.nil? ? nil : elapsed_s.to_f.round(3),
        'usage' => usage,
        'finish_reason' => finish_reason,
        'status' => status.to_s,
        'error' => error
      }
      @calls << call
      call
    end

    def add_role_receipt(**fields)
      receipt = RoleReceipt.new(**fields)
      @role_receipts << receipt
      receipt
    end

    def finish(status:)
      @status = status.to_s
      @finished_at = Runes::Compat.utc_iso8601(Time.now)
      self
    end

    def elapsed_s
      return nil if finished_at.nil?

      (Runes::Compat.monotonic - @started_monotonic).round(3)
    end

    def call_count
      @calls.size
    end

    def role_receipt_count
      @role_receipts.size
    end

    def to_h
      {
        'run_id' => run_id,
        'model' => model,
        'sampler' => sampler,
        'arm' => arm,
        'case_id' => case_id,
        'shape' => shape,
        'calibration' => calibration,
        'peak_memory_mb' => peak_memory_mb,
        'started_at' => started_at,
        'finished_at' => finished_at,
        'status' => status,
        'calls' => calls,
        'call_count' => call_count,
        'role_receipts' => role_receipts.map(&:to_h),
        'role_receipt_count' => role_receipt_count,
        'cost_usd' => cost_usd
      }
    end
  end
end
