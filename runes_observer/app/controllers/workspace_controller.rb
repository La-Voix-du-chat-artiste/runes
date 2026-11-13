# The workspace shell (docs/WORKSPACE_PLAN.md slice 1): one page that embeds
# the surfaces that used to be separate pages — the live communication feed,
# the fleet board, the agents and the recent runs — so a human can watch the
# fleet and the plan in a single space. Everything here is read-only; the
# write surfaces (documents, connectors, plan composer, board moves) land in
# later slices behind the token gate.
class WorkspaceController < ApplicationController
  FEED_LIMIT = 30
  BOARD_WINDOW = 24.hours
  BOARD_LIMIT = 9
  RUNS_LIMIT = 5
  AGENTS_LIMIT = 8

  def index
    @status = ingest_status
    @stats = {
      online: Agent.online.count,
      last_5m: Packet.since(5.minutes.ago).count,
      total_packets: observed_packet_count,
      runs: WorkflowRun.count
    }

    # Communication: the live tail, polled by the feed controller.
    @recent = Packet.recent.limit(FEED_LIMIT).to_a
    @last_id = @recent.map(&:id).max || 0

    # Mes tâches: the fleet board, folded from the same packets.
    @board = Board::Kanban.new(window: BOARD_WINDOW, limit: BOARD_LIMIT)
    @columns = @board.columns
    @truncated = @board.truncated

    # The agents working right now, plus the declared/observed drift badge.
    @online = Agent.online.by_activity.limit(AGENTS_LIMIT).to_a
    @declaration = FleetDeclaration.overview
    @drift = fleet_drift

    # Flux de travail: the most recent workflow runs.
    @runs = WorkflowRun.recent.limit(RUNS_LIMIT).includes(:workflow_steps).to_a
  end

  private

  # Drift needs the observed graph; building it is the topology page's job,
  # so here we only count undeclared agents cheaply when a declaration is in
  # effect. The full four-bucket view stays on /topology.
  def fleet_drift
    return nil unless @declaration

    declared = @declaration.roles.map(&:id)
    observed = Agent.distinct.pluck(:agent_id)
    undeclared = observed - declared
    silent = declared - observed
    { undeclared: undeclared, silent: silent, fingerprint: @declaration.fingerprint }
  end
end
