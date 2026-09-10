# Folds the engine's telemetry events into workflow_runs / workflow_steps.
#
# The engine publishes four event kinds per run and this is the only place that
# understands their order, so the views stay dumb:
#
#   run_started    -> create the run (workflow, params, started_at)
#   step_started   -> create a step row in "running"
#   step_finished  -> close that step (status, duration, output, error)
#   run_finished   -> close the run (status, duration, error, step count)
#
# Idempotent by construction: events key on the run id, steps key on
# (run, index), so a replayed retained message or a reconnect cannot duplicate
# a run. Every write is guarded — a malformed event must not stop ingest.
class WorkflowRunProjector
  # An event may arrive for a run whose run_started we never saw (the observer
  # started mid-run). The row is created on demand instead of dropping it.
  def self.apply(packet)
    new(packet).apply
  end

  def initialize(packet)
    @packet = packet
    @data = packet.parsed || {}
    @run_id = (packet.run_id.presence || @data["run_id"]).to_s
  end

  def apply
    return nil if @run_id.empty?

    case @packet.event.to_s
    when "run_started"    then start_run
    when "step_started"   then start_step
    when "step_finished"  then finish_step
    when "run_finished"   then finish_run
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[observer] workflow projection failed for #{@run_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def run
    @run ||= WorkflowRun.find_or_initialize_by(run_id: @run_id)
  end

  def start_run
    run.workflow = @data["workflow"].to_s.presence || run.workflow || "unknown"
    run.started_at ||= event_time
    run.status = "running"
    run.params = JSON.generate(@data["params"]) if @data["params"].is_a?(Hash)
    run.agent_id ||= @packet.agent_id
    run.save!
    run
  end

  def start_step
    step = step_for
    step.rune = @data["rune"].to_s
    step.name = @data["name"].to_s
    step.scope = @data["scope"].to_s.presence
    step.async = !!@data["async"]
    step.status = "running"
    step.started_at ||= event_time
    step.save!
    touch_run
    step
  end

  def finish_step
    step = step_for
    step.rune ||= @data["rune"].to_s
    step.name ||= @data["name"].to_s
    step.scope ||= @data["scope"].to_s.presence
    step.status = @data["status"].to_s.presence || "ok"
    step.duration_ms = @data["duration_ms"].to_f if @data["duration_ms"]
    step.finished_at ||= event_time
    step.output = @data["output"].to_s if @data["output"]
    step.error = @data["error"].to_s if @data["error"]
    step.save!
    touch_run
    step
  end

  def finish_run
    run.workflow ||= @data["workflow"].to_s.presence
    run.started_at ||= event_time
    run.finished_at ||= event_time
    run.status = @data["status"].to_s.presence || "ok"
    run.duration_ms = @data["duration_ms"].to_f if @data["duration_ms"]
    run.error = @data["error"].to_s if @data["error"]
    run.save!
    # The engine reports how many steps it ran; trust the rows if they disagree
    # (a dropped event should not make the header lie about the timeline).
    run.update_column(:step_count, [run.workflow_steps.count, @data["steps"].to_i].max)
    run
  end

  # Steps are keyed by the engine's run-wide index, which is what makes an
  # out-of-order (async) arrival land on the right row.
  #
  # The run is persisted first: a step that arrives before run_started (the
  # observer started mid-run) must still land, and its foreign key has to
  # point at a row.
  def step_for
    unless run.persisted?
      run.workflow = @data["workflow"].to_s.presence || run.workflow || "unknown"
      run.started_at ||= event_time
      run.save!
    end
    run.workflow_steps.find_or_initialize_by(position: @data["index"].to_i)
  end

  def event_time
    @event_time ||= begin
      Time.zone.parse(@data["at"].to_s)
    rescue ArgumentError, TypeError
      @packet.occurred_at || Time.current
    end
  end

  def touch_run
    run.started_at ||= @packet.occurred_at
    run.step_count = run.workflow_steps.count
    run.save! if run.changed?
  end
end
