# Workspace slice 2C (docs/WORKSPACE_PLAN.md): the plan read view. Epics and
# missions come from the workspace docs dir via MissionStore — the same files
# the TUI writes — and each mission renders its board (the `.mmd` when
# present, else the sidecar todos). Read-only here; the composer that writes
# epics and publishes plan prompts lands in slice 3 behind the token gate.
class PlanController < ApplicationController
  def index
    @workspace_root = MissionStore.root
    @epics = MissionStore.epics
    @missions = MissionStore.missions
    @boards = @missions.to_h { |m| [m.id, MissionStore.board_for(m)] }
  end

  def show
    @mission = MissionStore.find_mission(params[:id])
    raise ActionController::RoutingError, "no such mission" unless @mission

    @board = MissionStore.board_for(@mission)
    @body = MissionStore.mission_body(@mission)
    @packets = Packet.where("payload LIKE ?", "%#{@mission.id}%").recent.limit(20).to_a
  end
end
