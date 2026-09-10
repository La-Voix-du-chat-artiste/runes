class AgentsController < ApplicationController
  # One busy agent can have thousands of requests and hundreds of thousands
  # of packets; the page must stay bounded (O5-4).
  INTERACTIONS_PER_PAGE = 15
  PACKETS_PER_INTERACTION = 50
  HISTORY_LIMIT = 100

  def index
    @query = params[:q].to_s
    @state = params[:state].presence

    scope = Agent.search(@query)
    scope = scope.where(state: @state) if @state
    @agents = scope.by_activity.to_a
    @counts = {
      all: Agent.count,
      online: Agent.online.count,
      offline: Agent.ended.count,
      unknown: Agent.where(state: "unknown").count
    }
  end

  def show
    @agent = Agent.find_by(agent_id: params[:agent_id])
    unless @agent
      redirect_to agents_path, alert: "No agent ##{params[:agent_id]} has been observed."
      return
    end

    @page = [params[:page].to_i, 1].max
    agent_scope = Packet.for_agent(@agent.agent_id)
    @packets = agent_scope.recent.limit(HISTORY_LIMIT).to_a
    @last_id = @packets.map(&:id).max || 0
    @request_count = interaction_request_count(@agent.agent_id)
    @total_pages = [(@request_count.to_f / INTERACTIONS_PER_PAGE).ceil, 1].max
    @interactions = interactions_for(@agent.agent_id)
    @stats = {
      packets: agent_scope.count,
      requests: @request_count,
      first_seen: agent_scope.minimum(:occurred_at),
      kinds: agent_scope.group(:kind).count.sort_by { |_kind, count| -count }.first(8).to_h
    }
  end

  private

  # How many requests this agent executed. Requests it executed are
  # discovered through the packets that carry the agent id (topics with the
  # id embedded, or the journal backfill).
  def interaction_request_count(agent_id)
    Packet.for_agent(agent_id).where.not(request_id: nil).distinct.count(:request_id)
  end

  # Per interaction: the row count plus at most the last
  # PACKETS_PER_INTERACTION packets — never the whole correlation set.
  def interactions_for(agent_id)
    ids = Packet.for_agent(agent_id).where.not(request_id: nil)
                                   .group(:request_id)
                                   .order(Arel.sql("MAX(id) DESC"))
                                   .limit(INTERACTIONS_PER_PAGE)
                                   .offset((@page - 1) * INTERACTIONS_PER_PAGE)
                                   .pluck(:request_id)

    ids.map do |request_id|
      scope = Packet.for_request(request_id)
      {
        request_id: request_id,
        count: scope.count,
        prompt: scope.of_kind("prompt").first&.parsed&.dig("prompt"),
        packets: scope.recent.limit(PACKETS_PER_INTERACTION).to_a.reverse
      }
    end
  end
end
