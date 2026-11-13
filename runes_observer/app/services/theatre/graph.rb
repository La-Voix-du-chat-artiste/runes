# frozen_string_literal: true

# The theatre graph (docs/WORKSPACE_PLAN.md slice 2D): every agent working
# together, in one picture. Observed nodes/edges come from FleetTopology
# (packets in the window); the DECLARED fleet (FleetDeclaration) is merged in
# so silent roles and declared-but-unobserved routes show up as dashed —
# the same drift the /topology page reports, drawn.
#
# Positions come from FleetTopology::Layout (deterministic circle), so the
# server-rendered SVG and the client-side particle animation share one
# geometry: the view embeds #to_h as JSON and the Stimulus controller animates
# along exactly these coordinates.
module Theatre
  class Graph
    WINDOW = 30.minutes

    def initialize(window: WINDOW)
      @window = window
    end

    def to_h
      observed_nodes, observed_edges = FleetTopology.build(packets: Packet.since(@window.ago))
      declaration = FleetDeclaration.overview
      declared_ids = declaration ? declaration.roles.map(&:id) : []
      declared_pairs = declaration ? declaration.edges.map { |e| [e.from, e.to] }.uniq : []
      observed_pairs = observed_edges.map { |e| [e.from, e.to] }.uniq

      nodes = observed_nodes.dup
      (declared_ids - observed_nodes.map(&:agent_id)).each do |id|
        nodes << FleetTopology::Node.new(agent_id: id, state: "silent", display_state: "silent",
                                         packets: 0, tools: 0, inbound: 0, outbound: 0,
                                         executed: 0, errors: 0, last_seen_at: nil)
      end
      edges = observed_edges.dup
      (declared_pairs - observed_pairs).each do |from, to|
        edges << FleetTopology::Edge.new(from: from, to: to, tasks: 0, replies: 0, errors: 0,
                                         avg_ms: nil, max_ms: nil, last_at: nil, latencies: [])
      end

      layout = FleetTopology::Layout.new(nodes, edges)
      {
        window_minutes: (@window / 60).round,
        nodes: layout.placed.map do |p|
          {
            id: p.node.agent_id, state: p.node.display_state,
            x: p.x, y: p.y, r: p.radius,
            declared: declared_ids.include?(p.node.agent_id)
          }
        end,
        edges: layout.wires.map do |w|
          pair = [w.edge.from, w.edge.to]
          {
            from: w.edge.from, to: w.edge.to,
            x1: w.x1, y1: w.y1, x2: w.x2, y2: w.y2, cx: w.cx, cy: w.cy,
            tasks: w.edge.tasks,
            declared: declared_pairs.include?(pair) && !observed_pairs.include?(pair)
          }
        end
      }
    end
  end
end
