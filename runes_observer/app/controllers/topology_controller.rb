# The fleet as a graph: who delegates to whom, how often, and how it went.
# The DECLARED fleet (a loaded .fleet.rb, FleetDeclaration) renders beside
# the OBSERVED one, with the drift between them — silent roles, undeclared
# agents and routes.
class TopologyController < ApplicationController
  def show
    @nodes, @edges = FleetTopology.build
    @layout = FleetTopology::Layout.new(@nodes, @edges)
    @observed_by_pair = @edges.to_h { |edge| [[edge.from, edge.to], edge] }
    @declaration = FleetDeclaration.overview
    @drift = FleetDeclaration.drift(@nodes, @edges) if @declaration
    @declaration_error = FleetDeclaration.error unless @declaration
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
