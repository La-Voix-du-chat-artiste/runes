# Workspace slice 2D (docs/WORKSPACE_PLAN.md): the theatre — all agents
# working together in one live picture. The graph geometry is computed
# server-side (Theatre::Graph over FleetTopology + the declared fleet) and
# rendered as SVG; the Stimulus controller animates message particles along
# the same coordinates from the /feed poller. /wall is the kiosk: same graph,
# no nav, meta refresh.
class TheatreController < ApplicationController
  def show
    @graph = Theatre::Graph.new.to_h
  end

  def wall
    @graph = Theatre::Graph.new.to_h
    render :show, layout: "kiosk"
  end
end
