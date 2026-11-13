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

  # --- slice 3 write actions (non-GET, so behind the token gate) -----------

  # Write an epic file into the workspace docs dir (same naming as the
  # dispatcher's write_artifact), then announce it on the fabric.
  def create_epic
    path = MissionStore.write_epic(params[:body].to_s)
    FabricPublisher.publish("runes/docs/added", {
      "sha" => Digest::SHA256.file(path).hexdigest, "ext" => "md",
      "bytes" => File.size(path), "name" => File.basename(path),
      "uploaded_by" => "observatory-ui", "kind" => "epic"
    })
    redirect_to plan_path, notice: "Epic written: #{File.basename(path)}"
  rescue MissionStore::Error => e
    redirect_to plan_path, alert: e.message
  end

  # Publish the planning prompt for an epic — the exact envelope the TUI's
  # /plan sends (`mode: "plan"`, `epic_path:`), so the existing planner agents
  # do the work; the observer stays a participant, not a second planner.
  def plan_epic
    path = MissionStore.epic_path(params[:id])
    raise ActionController::RoutingError, "no such epic" unless path

    request_id = SecureRandom.uuid[0, 12]
    published = FabricPublisher.publish("runes/prompts", {
      "request_id" => request_id,
      "mode" => "plan",
      "prompt" => params[:prompt].to_s,
      "epic_path" => path
    })
    if published
      redirect_to plan_path, notice: "Plan requested (#{request_id}) — watch /packets and /board."
    else
      redirect_to plan_path, alert: "Could not reach the fabric (publish failed) — the epic file is untouched."
    end
  end

  # Move one card on the mission board: parse the .mmd through Runes::Kanban,
  # move, re-render, atomic write, journal, announce on the fabric.
  def move_card
    mission = MissionStore.find_mission(params[:id])
    raise ActionController::RoutingError, "no such mission" unless mission

    result = MissionStore.move_card(mission, index: params[:index].to_i, to: params[:to].to_s)
    if result[:error]
      render plain: result[:error], status: :unprocessable_entity and return
    end

    MissionStore.append_journal(
      "event" => "board_card_moved", "mission" => mission.id,
      "card" => result[:title], "from" => result[:from], "to" => result[:to],
      "by" => "observatory-ui"
    )
    FabricPublisher.publish("runes/board/moved", {
      "mission" => mission.id, "card" => result[:title],
      "from" => result[:from], "to" => result[:to], "by" => "observatory-ui"
    })
    respond_to do |format|
      format.json { render json: result }
      format.html { redirect_to plan_mission_path(mission.id), notice: "Moved “#{result[:title]}” → #{result[:to]}" }
    end
  end
end
