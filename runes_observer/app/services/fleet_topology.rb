# The fleet as a graph: who delegates to whom, how often, and how it goes.
#
# Everything here is derived from packets the observer already stores, and the
# derivation is deliberately conservative:
#
#   * an EDGE comes from an explicit `from` field on a delegation packet
#     (`runes/agents/<target>/tasks` carries `from`), because that is the only
#     place the harness states who sent the work;
#   * a `task_response` for the same request id completes that edge and gives
#     its latency;
#   * an A2A task whose sender is not in the payload is counted on the target
#     node as inbound work, NOT drawn as an edge — inventing an edge from a
#     topic that only names the receiver would be a lie with a nice picture.
#
# Pure and side-effect free so the whole derivation is unit-testable.
class FleetTopology
  Node = Struct.new(:agent_id, :state, :packets, :tools, :inbound, :outbound,
                    :executed, :errors, :last_seen_at, :display_state,
                    keyword_init: true) do
    def label = agent_id
    def degree = inbound + outbound
  end

  # `latencies` is a scratch accumulator, cleared once the edge is finalised.
  Edge = Struct.new(:from, :to, :tasks, :replies, :errors, :avg_ms, :max_ms, :last_at,
                    :latencies, keyword_init: true) do
    def completed? = replies.positive?
    def error_rate = tasks.positive? ? (errors.to_f / tasks) : 0.0

    def latency_label
      return "—" if avg_ms.nil?

      avg_ms < 1000 ? "#{avg_ms.round}ms" : "#{(avg_ms / 1000.0).round(2)}s"
    end
  end

  RESPONSE_ERROR_PREFIX = /\A\s*Error[:!]/i

  # Deterministic circular layout. No randomness and no physics: the same
  # fleet always draws the same picture, which means a screenshot, a test and
  # a second look agree.
  class Layout
    WIDTH = 960
    HEIGHT = 560
    PADDING = 120
    NODE_MIN = 15
    NODE_MAX = 34

    Placed = Struct.new(:node, :x, :y, :radius, :anchor, :label_x, :label_y, keyword_init: true)
    Wire = Struct.new(:edge, :x1, :y1, :x2, :y2, :cx, :cy, :width, :css_class, keyword_init: true)

    def initialize(nodes, edges, width: WIDTH, height: HEIGHT)
      @nodes = nodes
      @edges = edges
      @width = width
      @height = height
    end

    def placed
      @placed ||= @nodes.each_with_index.map do |node, index|
        angle = -Math::PI / 2 + (2 * Math::PI * index / [@nodes.size, 1].max)
        x = centre_x + radius_x * Math.cos(angle)
        y = centre_y + radius_y * Math.sin(angle)
        Placed.new(node: node, x: x.round(1), y: y.round(1), radius: node_radius(node),
                   anchor: anchor_for(x), label_x: label_x(x, node).round(1),
                   label_y: (y + 4).round(1))
      end
    end

    def wires
      map = placed.each_with_object({}) { |p, out| out[p.node.agent_id] = p }
      @edges.filter_map do |edge|
        from = map[edge.from]
        to = map[edge.to]
        next if from.nil? || to.nil?

        Wire.new(edge: edge, x1: from.x, y1: from.y, x2: to.x, y2: to.y,
                 cx: ((from.x + to.x) / 2 * 0.88 + centre_x * 0.12).round(1),
                 cy: ((from.y + to.y) / 2 * 0.88 + centre_y * 0.12).round(1),
                 width: (1.0 + Math.log2(edge.tasks + 1) * 1.6).round(2),
                 css_class: edge.error_rate > 0.2 ? "wire--error" : "wire--ok")
      end
    end

    def empty? = @nodes.empty?

    private

    def centre_x = @width / 2.0
    def centre_y = @height / 2.0
    def radius_x = [(@width / 2.0) - PADDING, 40].max
    def radius_y = [(@height / 2.0) - PADDING, 40].max

    def node_radius(node)
      size = NODE_MIN + Math.log2(node.packets + 1) * 3.2 + (node.degree * 2.0)
      size.clamp(NODE_MIN, NODE_MAX).round(1)
    end

    def anchor_for(x)
      return "middle" if (x - centre_x).abs < 24

      x < centre_x ? "end" : "start"
    end

    def label_x(x, node)
      gap = node_radius(node) + 6
      anchor_for(x) == "end" ? x - gap : (anchor_for(x) == "start" ? x + gap : x)
    end
  end

  class << self
    # @return [Array(Array<Node>, Array<Edge>)]
    def build(agents: Agent.all, packets: Packet.all)
      nodes = {}
      index_agents(nodes, agents)
      edges = {}
      task_index = {}

      packets.chronological.find_each do |packet|
        node_for(nodes, packet.agent_id) if packet.agent_id.present?
        case packet.kind
        when "task" then record_task(nodes, edges, task_index, packet)
        when "a2a_task" then record_a2a_task(nodes, packet)
        when "task_response" then record_reply(nodes, edges, task_index, packet)
        when "progress", "response" then record_execution(nodes, packet)
        when "tool_error" then record_error(nodes, packet)
        end
      end

      # An edge whose sender never appeared in a card still deserves a node.
      edges.each_value do |edge|
        node_for(nodes, edge.from)
        node_for(nodes, edge.to)
      end
      edges.each_value { |edge| finalize_latency(edge) }

      [nodes.values.sort_by { |node| [-node.degree, -node.packets, node.agent_id] },
       edges.values.sort_by { |edge| [-edge.tasks, edge.from, edge.to] }]
    end

    private

    def index_agents(nodes, agents)
      agents.find_each do |agent|
        node = node_for(nodes, agent.agent_id)
        node.state = agent.state
        node.display_state = agent.display_state
        node.tools = agent.tools_list.size
        node.last_seen_at = agent.last_seen_at
        node.packets = [node.packets, agent.packet_count.to_i].max
      end
    end

    def node_for(nodes, agent_id)
      nodes[agent_id] ||= Node.new(agent_id: agent_id, state: "unknown", display_state: "unknown",
                                   packets: 0, tools: 0, inbound: 0, outbound: 0,
                                   executed: 0, errors: 0)
    end

    # A delegation: the topic names the target, the payload's `from` names the
    # delegator. Both ends are stated, so this is a real edge.
    def record_task(nodes, edges, task_index, packet)
      target = packet.agent_id
      from = packet.parsed&.dig("from").to_s
      return if target.nil?

      node_for(nodes, target).inbound += 1
      return if from.empty? || from == target

      node_for(nodes, from).outbound += 1
      edge = edge_for(edges, from, target)
      edge.tasks += 1
      edge.last_at = packet.occurred_at
      task_index[packet.request_id] = { edge: edge, at: packet.occurred_at } if packet.request_id.present?
    end

    # An A2A task only names its receiver in the topic; the sender is not in
    # the payload. Count it as inbound work rather than guess an edge.
    def record_a2a_task(nodes, packet)
      return if packet.agent_id.nil?

      node_for(nodes, packet.agent_id).inbound += 1
    end

    def record_reply(nodes, edges, task_index, packet)
      # The reply topic belongs to the DELEGATOR (`runes/agents/<from>/tasks/
      # <req>/response`), so this packet's agent is the edge's source.
      delegator = packet.agent_id
      node_for(nodes, delegator).packets += 1 if delegator.present?

      tracked = task_index[packet.request_id]
      return if tracked.nil?

      edge = tracked[:edge]
      edge.replies += 1
      edge.errors += 1 if packet.payload.to_s.match?(RESPONSE_ERROR_PREFIX)
      latency = ((packet.occurred_at - tracked[:at]) * 1000)
      edge.latencies ||= []
      edge.latencies << latency if latency.positive?
    end

    def record_execution(nodes, packet)
      node = node_for(nodes, packet.agent_id)
      node.executed += 1
      node.packets += 1
    end

    def record_error(nodes, packet)
      return if packet.agent_id.nil?

      node_for(nodes, packet.agent_id).errors += 1
    end

    def edge_for(edges, from, to)
      edges[[from, to]] ||= Edge.new(from: from, to: to, tasks: 0, replies: 0, errors: 0)
    end

    def finalize_latency(edge)
      latencies = edge.latencies
      return if latencies.nil? || latencies.empty?

      edge.avg_ms = latencies.sum / latencies.size
      edge.max_ms = latencies.max
      edge.latencies = nil
    end
  end
end
