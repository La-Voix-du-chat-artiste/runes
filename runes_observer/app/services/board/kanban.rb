# The fleet board: what is planned, what is being worked on, what is done.
#
# Why a Mermaid `kanban` diagram and not a hand-built column view: the diagram
# *text* is an artifact. It renders in the browser, it is readable in a `GET
# /board.mmd`, and an agent (or `bin/runes-replay`, or you over ssh) can read the
# fleet's work state without a browser. The HTML fallback in the Stimulus
# controller means the board is visible even when Mermaid is missing.
#
# Cards are units of work folded out of the packet stream the observer already
# stores — no new ingestion, and no guessing:
#
#   Planned   plan_ready announced N steps; a mission was written; an A2A task
#             was addressed to an agent
#   Working   prompt_received, step_start <tool>, mission_step_start <title>
#   Done      step_end, prompt_complete, mission_step_done/failed,
#             mission_complete, and every journal entry (which is written at
#             the end of a lifecycle and carries the prompt text)
#
# The fold is chronological and keyed, so a step that was planned becomes the
# same card when it starts and when it finishes: that motion is the point of a
# board. A card whose last signal is old stays in Working with its age shown —
# the board reports a wedged request instead of quietly moving it along.
module Board
  class Kanban
    PLANNED = "Planned"
    WORKING = "Working"
    DONE = "Done"
    COLUMNS = [PLANNED, WORKING, DONE].freeze

    DEFAULT_WINDOW = 24.hours
    DEFAULT_LIMIT = 40
    # A working card with no signal for this long is shown as stale (⚠), not
    # moved: "quiet" is not "finished", and the observer's job is to say so.
    STALE_AFTER = 30.minutes
    # Folding is O(packets): cap the read, and say so in the header.
    MAX_PACKETS = 5_000
    LABEL_BYTES = 90

    # One unit of work. `key` is stable across its whole life, which is what
    # lets a planned step become a working one without becoming a new card.
    Card = Struct.new(:key, :column, :agent, :title, :detail, :at, :request_id,
                      :packet_id, :error, :stale, keyword_init: true) do
      def stale?(now)
        column == WORKING && (now - at) > Kanban::STALE_AFTER
      end

      def label
        text = [agent.presence, title.presence].compact.join(" · ")
        text = key if text.empty?
        text = "#{text} — #{detail}" if detail.present?
        text = "⚠ #{text}" if error || stale
        text
      end
    end

    attr_reader :window, :agent_id, :limit, :now

    def initialize(scope: Packet.all, window: DEFAULT_WINDOW, agent_id: nil,
                   limit: DEFAULT_LIMIT, now: Time.current)
      @scope = scope
      @window = window
      @agent_id = agent_id.presence
      @limit = [limit.to_i, 1].max
      @now = now
      @items = {}
      @truncated = {}
      @packets_read = 0
    end

    def cards
      build unless @built
      @cards
    end

    def columns
      grouped = cards.group_by(&:column)
      COLUMNS.to_h { |column| [column, grouped[column] || []] }
    end

    def truncated
      build unless @built
      @truncated
    end

    def packets_read
      build unless @built
      @packets_read
    end

    # The agents that appear on the board, for the filter control.
    def agents
      cards.filter_map(&:agent).uniq.sort
    end

    # Mermaid `kanban` text. `%%` lines are comments to Mermaid, so the header
    # carries the provenance (window, filter, truncation) without breaking the
    # diagram.
    def to_mmd
      build unless @built
      header = [
        "%% Runes fleet board — generated #{now.utc.iso8601}",
        "%% window: last #{human_window} · agent: #{agent_id || 'all'} · " \
        "cards: #{cards.size}#{truncation_note}"
      ]
      lines = header + ["kanban"]
      columns.each do |column, list|
        lines << "  #{column_id(column)}[#{column}]"
        list.each_with_index do |card, index|
          lines << %(    #{card_id(column, index)}["#{escape(card.label)}"])
        end
      end
      lines.join("\n") << "\n"
    end

    # Grammar check for the generated text, used by the tests so a malformed
    # diagram fails the suite rather than rendering as an error box in a
    # browser nobody is looking at.
    def self.validate(text)
      errors = []
      column = nil
      seen_ids = {}
      saw_kanban = false
      text.to_s.each_line.with_index(1) do |line, number|
        stripped = line.chomp
        next if stripped.strip.empty? || stripped.start_with?("%%")

        if stripped.strip == "kanban"
          errors << "line #{number}: kanban must be the first non-comment line" if saw_kanban
          saw_kanban = true
          next
        end

        unless saw_kanban
          errors << "line #{number}: kanban must be the first non-comment line"
          next
        end

        if (match = stripped.match(/\A {2}([A-Za-z0-9_]+)\[([^\]]+)\]\z/))
          column = match[2]
          errors << "line #{number}: unknown column #{column.inspect}" unless COLUMNS.include?(column)
        elsif (match = stripped.match(/\A {4}([A-Za-z0-9_]+)\["([^"]*)"\]\z/))
          errors << "line #{number}: a card outside any column" if column.nil?
          errors << "line #{number}: duplicate card id #{match[1]}" if seen_ids[match[1]]
          seen_ids[match[1]] = true
          errors << "line #{number}: empty card label" if match[2].strip.empty?
        else
          errors << "line #{number}: not kanban syntax: #{stripped.inspect}"
        end
      end
      errors
    end

    private

    def build
      @built = true
      rows = @scope.where("occurred_at >= ?", now - window)
                   .order(:occurred_at, :id)
                   .limit(MAX_PACKETS)
                   .to_a
      @packets_read = rows.size
      rows.each { |packet| fold(packet) }

      selected = @items.values
      selected = selected.select { |card| card.agent == agent_id } if agent_id
      selected.each { |card| card.stale = true if card.stale?(now) }
      grouped = selected.group_by(&:column)
      COLUMNS.each do |column|
        list = (grouped[column] || []).sort_by { |card| [-card.at.to_f, card.key] }
        @truncated[column] = [list.size - limit, 0].max
        grouped[column] = list.first(limit)
      end
      @cards = COLUMNS.flat_map { |column| grouped[column] || [] }
    end

    def fold(packet)
      data = packet.parsed || {}
      event = (packet.event || data["event"]).to_s
      case packet.kind
      when "progress" then fold_progress(packet, event, data)
      when "journal" then fold_journal(packet, data)
      when "a2a_task", "task" then fold_task(packet, data)
      end
    end

    def fold_progress(packet, event, data)
      request = packet.request_id.presence || data["request_id"].presence
      case event
      when "prompt_received"
        upsert("request:#{request}", packet, column: WORKING,
                                      title: data["prompt"], detail: "planning")
      when "plan_ready"
        steps = data["steps"].to_i
        upsert("request:#{request}", packet, column: WORKING,
                                      detail: "#{steps} step#{"s" unless steps == 1} planned")
        # The step names are not published until each one starts, so a planned
        # step is honestly "step N" — it becomes a named card the moment the
        # planner reaches it.
        1.upto(steps) do |index|
          upsert("step:#{request}:#{index}", packet, column: PLANNED,
                                               title: "step #{index}", request_id: request,
                                               at: packet.occurred_at)
        end
      when "step_start"
        upsert("step:#{request}:#{data['step']}", packet, column: WORKING,
                                                    title: data["tool"], request_id: request)
      when "step_end"
        upsert("step:#{request}:#{data['step']}", packet, column: DONE,
                                                    title: data["tool"], request_id: request,
                                                    detail: first_line(data["outcome"]))
      when "prompt_complete"
        close_request(request, packet, detail: nil)
      when "plan_empty", "planner_error", "plan_truncated", "prompt_truncated", "duplicate_ignored"
        close_request(request, packet, detail: event, error: event != "duplicate_ignored")
      when "mission_written"
        upsert("mission:#{request}", packet, column: PLANNED,
                                      title: mission_title(data), request_id: request,
                                      detail: "#{data['todos'].to_i} todo(s) written")
      when "mission_started"
        upsert("mission:#{request}", packet, column: WORKING,
                                      title: mission_title(data), request_id: request,
                                      detail: "#{data['pending'].to_i} of #{data['total'].to_i} todo(s) pending")
      when "mission_step_start"
        upsert("todo:#{request}:#{data['todo_id']}", packet, column: WORKING,
                                                     title: data["title"], request_id: request)
      when "mission_step_done", "mission_step_failed"
        upsert("todo:#{request}:#{data['todo_id']}", packet, column: DONE,
                                                     title: data["title"], request_id: request,
                                                     detail: data["verdict"] || event.delete_prefix("mission_step_"),
                                                     error: event == "mission_step_failed")
      when "mission_complete"
        close_request(request, packet, detail: "mission complete")
      end
    end

    # The journal is written at the end of a lifecycle and carries the prompt
    # text, so it is the board's best source of titled finished work — and the
    # only one for a request whose progress events the observer never saw.
    def fold_journal(packet, data)
      request = packet.request_id.presence || data["request_id"].presence
      return if request.nil?

      status = data["status"].to_s
      prompt = data["prompt"].to_s
      detail = [status, first_line(data["summary"] || data["error"])].compact_blank.join(" — ")
      failed = status.match?(/error|failed|invalid/i)

      # A `mission_step` entry is one todo finishing ("todo <id>: <title>"), not
      # the mission finishing: close the todo card, and leave the mission where
      # it is.
      if status == "mission_step" && (match = prompt.match(/\Atodo (\S+?):\s*(.+)\z/m))
        upsert("todo:#{request}:#{match[1]}", packet, column: DONE, request_id: request,
                                                   title: match[2], detail: detail, error: failed)
        return
      end

      card = @items["request:#{request}"] || @items["mission:#{request}"]
      if card && !terminal_journal_status?(status)
        # A mid-lifecycle entry (planning, a goal turn, chat): annotate, never
        # move. Moving it to Done here is how a board starts lying.
        card.detail = detail.presence || card.detail
        card.packet_id = packet.id
        card.error = true if failed
        return
      end

      if card
        card.column = DONE
        card.detail = detail.presence || card.detail
        card.at = packet.occurred_at
        card.packet_id = packet.id
        card.error = true if failed
      else
        upsert("request:#{request}", packet, column: DONE,
                                      title: prompt, detail: detail.presence, error: failed)
      end
    end

    TERMINAL_JOURNAL = %w[
      complete epic_written mission_written mission_complete mission_failed
      planner_error plan_empty plan_truncated prompt_truncated
    ].freeze

    def terminal_journal_status?(status)
      TERMINAL_JOURNAL.include?(status)
    end

    # An A2A task is work *assigned* to an agent: it belongs in Planned until
    # that agent starts it (at which point the progress events take over).
    def fold_task(packet, data)
      request = packet.request_id.presence || data["request_id"].presence || "packet-#{packet.id}"
      title = data.dig("params", "prompt") || data["prompt"] || data["method"] ||
              first_line(packet.headline)
      upsert("task:#{request}", packet, column: PLANNED,
                                    title: title, request_id: request)
    end

    def upsert(key, packet, column:, title: nil, detail: nil, request_id: nil,
               at: nil, error: false)
      return if key.nil? || key.end_with?(":")

      card = @items[key] ||= Card.new(key: key, column: column, at: at || packet.occurred_at,
                                      request_id: request_id || packet.request_id)
      card.column = column
      card.title = title if title.present?
      card.detail = detail if detail.present?
      card.error = true if error
      card.at = at || packet.occurred_at
      card.agent = packet.agent_id if packet.agent_id.present?
      card.packet_id = packet.id
      card.request_id ||= packet.request_id
      card
    end

    # A finished request finishes the steps nobody closed explicitly: a plan
    # that ends `prompt_complete` with a step still open is a fact about the
    # run, and leaving it in Working forever would be the board lying.
    def close_request(request, packet, detail:, error: false)
      return if request.nil?

      # A mission run's card is keyed `mission:` (it exists from
      # `mission_written`), so closing `request:` would leave the mission card
      # in Working for ever and invent a second card for the same work.
      key = @items.key?("mission:#{request}") ? "mission:#{request}" : "request:#{request}"
      upsert(key, packet, column: DONE, detail: detail, error: error)
      @items.each_value do |card|
        next if card.column == DONE
        next unless card.key.start_with?("step:#{request}:", "todo:#{request}:")

        # A step still open when the request ended was interrupted; a step
        # still in Planned was never reached. Both are closed — the request is
        # over, so leaving either in Working/Planned would be the board lying —
        # but the second is flagged, because "closed" is not "done".
        if card.column == WORKING
          card.detail ||= "closed with the request"
        else
          card.detail = "not started when the request finished"
          card.error = true
        end
        card.column = DONE
        card.at = packet.occurred_at
        card.packet_id = packet.id
      end
    end

    def mission_title(data)
      path = data["path"].to_s
      return nil if path.empty?

      File.basename(path, ".md")
    end

    def first_line(text)
      value = text.to_s.strip
      return nil if value.empty?

      value.lines.first.to_s.strip[0, 160]
    end

    def escape(text)
      value = text.to_s.gsub(/[\r\n\t]+/, " ").gsub('"', "'").delete("[]{}")
      value = value.squeeze(" ").strip
      return "…" if value.empty?

      value.bytesize > LABEL_BYTES ? "#{value.byteslice(0, LABEL_BYTES).scrub}…" : value
    end

    def column_id(column) = column.downcase

    def card_id(column, index) = "#{column_id(column)}_#{index + 1}"

    def truncation_note
      shown = truncated.values.sum
      shown.zero? ? "" : " (truncated: #{shown})"
    end

    def human_window
      seconds = window.to_i
      return "#{seconds / 3600} h" if (seconds % 3600).zero?
      return "#{seconds / 60} min" if (seconds % 60).zero?

      "#{seconds} s"
    end
  end
end
