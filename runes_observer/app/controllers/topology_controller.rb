# The fleet as a graph: who delegates to whom, how often, and how it went.
class TopologyController < ApplicationController
  def show
    @nodes, @edges = FleetTopology.build
    @layout = FleetTopology::Layout.new(@nodes, @edges)
    @stats = {
      agents: @nodes.size,
      online: @nodes.count { |n| n.display_state == "online" },
      edges: @edges.size,
      tasks: @edges.sum(&:tasks),
      errors: @edges.sum(&:errors),
      orphan_inbound: @nodes.sum { |n| n.inbound } - @edges.sum(&:tasks)
    }
  end
end
