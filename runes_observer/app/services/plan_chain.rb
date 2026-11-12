# O1.7 — "why did it do that?": the causal chain of one interaction, joined
# from the packets that carry its request_id:
#
#   prompt → plan → tool calls → evidence → verdict
#
# Pure read over Packet; the chain is ordered by occurred_at and each link
# names its packet kind so the view can render it as a chain, not a log.
class PlanChain
  Link = Struct.new(:kind, :label, :at, :packet, keyword_init: true)

  # progress events that carry the plan / verdict payloads
  PLAN_EVENTS = %w[plan_ready mission_planning].freeze
  VERDICT_EVENTS = %w[prompt_complete mission_complete mission_failed].freeze

  class << self
    def build(packets)
      new(packets).build
    end
  end

  def initialize(packets)
    @packets = packets.sort_by(&:occurred_at)
  end

  def build
    links = []
    prompt = @packets.find { |p| p.kind == "prompt" }
    links << link("prompt", "Prompt", prompt) if prompt

    @packets.select { |p| p.kind == "progress" && PLAN_EVENTS.include?(p.event.to_s) }
             .each { |p| links << link("plan", "Plan", p) }

    # tool calls: pair tool_request with its tool_response by tool id
    requests = @packets.select { |p| p.kind == "tool_request" }
    responses = @packets.select { |p| %w[tool_response tool_error].include?(p.kind) }
    requests.each do |req|
      resp = responses.find { |r| r.tool.to_s == req.tool.to_s && r.occurred_at >= req.occurred_at }
      links << link("tool_call", "Tool: #{req.tool}", req)
      links << link(resp&.kind == "tool_error" ? "tool_error" : "tool_response",
                    resp&.kind == "tool_error" ? "Tool failed: #{req.tool}" : "Tool ok: #{req.tool}", resp || req)
    end

    @packets.select { |p| p.kind == "progress" && VERDICT_EVENTS.include?(p.event.to_s) }
             .each { |p| links << link("verdict", "Verdict: #{p.event}", p) }

    response = @packets.find { |p| p.kind == "response" }
    links << link("response", "Response", response) if response

    links.sort_by! { |l| l.at || Time.at(0) }
    { links: links }
  end

  private

  def link(kind, label, packet)
    Link.new(kind: kind, label: label, at: packet&.occurred_at, packet: packet)
  end
end
