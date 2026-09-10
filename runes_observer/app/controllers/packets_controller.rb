class PacketsController < ApplicationController
  PER_PAGE = 200

  def index
    @kinds = Packet::KINDS
    @filters = filter_params
    @packets = filtered.recent.limit(PER_PAGE).to_a
    @last_id = @packets.map(&:id).max || 0
    @agents = Agent.by_activity.limit(100).pluck(:agent_id)
    # Reuse the layout's memoized total when nothing narrows the scope,
    # instead of running the same COUNT(*) twice (O5-7).
    @total = filters_active? ? filtered.count : observed_packet_count
    # The live tail keeps the active filters but paginates by id, so the
    # before_id cursor is not forwarded.
    @feed_params = @filters.compact.except(:before_id)
  end

  # The full payload, on demand: list views only ship a bounded summary.
  def show
    @packet = Packet.find(params[:id])
  end

  # JSON feed consumed by the Stimulus poller: rows are rendered with the
  # same partial used for the first page, so live and initial markup agree.
  # The partial serves a bounded summary, never the whole 256 KiB payload.
  def feed
    packets = filtered.after_id(params[:after_id] || 0).chronological.limit(PER_PAGE).to_a
    render json: {
      last_id: packets.map(&:id).max || params[:after_id].to_i,
      packets: packets.map { |packet| { id: packet.id, html: packet_html(packet) } },
      stats: { total: Packet.count, online: Agent.online.count, offline: Agent.ended.count }
    }
  end

  private

  def packet_html(packet)
    render_to_string(
      partial: "packets/packet",
      formats: [:html],
      locals: { packet: packet, show_agent: filter_params[:agent_id].blank? }
    )
  end

  def filter_params
    @filter_params ||= params.permit(:agent_id, :kind, :request_id, :topic, :q, :since, :before_id)
                            .to_h.symbolize_keys
  end

  def filters_active?
    filter_params.values.any?(&:present?)
  end

  def filtered
    scope = Packet.all
    fp = filter_params
    scope = scope.for_agent(fp[:agent_id]) if fp[:agent_id].present?
    scope = scope.of_kind(fp[:kind]) if fp[:kind].present?
    scope = scope.for_request(fp[:request_id]) if fp[:request_id].present?
    if fp[:topic].present?
      scope = scope.where("topic LIKE ? ESCAPE '\\'", "%#{Packet.sanitize_sql_like(fp[:topic])}%")
    end
    if fp[:q].present?
      # `%` and `_` are LIKE metacharacters: escape them so a literal search
      # does not turn into a full scan that matches everything (O5-6).
      scope = scope.where("payload LIKE ? ESCAPE '\\'", "%#{Packet.sanitize_sql_like(fp[:q])}%")
    end
    if fp[:since].present? && fp[:since].to_i.positive?
      scope = scope.since(fp[:since].to_i.minutes.ago)
    end
    scope = scope.before_id(fp[:before_id]) if fp[:before_id].present?
    scope
  end
end
