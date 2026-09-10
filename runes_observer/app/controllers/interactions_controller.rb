# One logical interaction: a build/goal request, reconstructed from every
# packet that carries that request_id.
#
# Phase 16 deleted the session-lease protocol, so `request_id` is the only
# correlation key the harness publishes.
class InteractionsController < ApplicationController
  def show
    @id = params[:id].to_s
    @packets = Packet.for_request(@id).chronological.to_a
    @agents = @packets.filter_map(&:agent_id).uniq
    @prompt = @packets.find { |packet| packet.kind == "prompt" }&.parsed&.dig("prompt")
  end
end
