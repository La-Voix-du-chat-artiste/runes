# frozen_string_literal: true

# Read view over the workspace's planning artifacts (docs/WORKSPACE_PLAN.md
# slice 2C): epics in `docs/epics/*.md`, missions in `docs/missions/*.md`
# with their `.json` sidecar (mission_title, source, todos) — the exact files
# the TUI's /goal, /plan and /build write through the dispatcher's
# write_artifact. The FILE is the source of truth; nothing is mirrored into
# the observer's database.
#
# A mission may also carry a `<id>.mmd` kanban (the Runes::Kanban contract),
# parsed here so the plan page can render the planned tasks as a board.
#
# Root: `RUNES_OBSERVER_WORKSPACE` when set, else the harness's own
# Runes::Core::Settings.default_root (RUNES_ROOT aware) — the same root the
# TUI uses, so the observer and the terminal see the same missions.
begin
  require "runes/kanban"
  require "runes/core/settings"
rescue LoadError
  # The UI still boots without the harness; boards then derive from the
  # sidecar todos and epic/mission listing still works.
end

class MissionStore
  Error = Class.new(StandardError)

  Epic    = Struct.new(:id, :path, :title, :mtime, keyword_init: true)
  Mission = Struct.new(:id, :path, :title, :todos, :source, :source_path, :mtime,
                       keyword_init: true)

  ID_RE = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  MAX_EPIC_BYTES = 20_000

  class << self
    def root
      @root ||= begin
        explicit = ENV.fetch("RUNES_OBSERVER_WORKSPACE", "").strip
        explicit.empty? ? harness_default_root : explicit
      end
    end

    def harness_default_root
      defined?(Runes::Core::Settings) ? Runes::Core::Settings.default_root : Dir.pwd
    end

    def kanban_available?
      defined?(Runes::Kanban) ? true : false
    end

    def epics
      dir = File.join(root, "docs", "epics")
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "*.md")).sort_by { |p| File.mtime(p) }.reverse.map do |path|
        Epic.new(id: File.basename(path, ".md"), path: path,
                 title: heading_of(path), mtime: File.mtime(path))
      end
    end

    def missions
      dir = File.join(root, "docs", "missions")
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "*.md")).sort_by { |p| File.mtime(p) }.reverse.map do |path|
        mission_for(path)
      end
    end

    # Containment-checked lookup: the id is a plain basename inside
    # docs/missions (same rule as the dispatcher's epic path check).
    def find_mission(id)
      return nil unless id.to_s.match?(ID_RE) && !id.to_s.include?("..")

      path = File.join(root, "docs", "missions", "#{id}.md")
      File.file?(path) ? mission_for(path) : nil
    end

    # The mission's board: the `<id>.mmd` file parsed through the harness's
    # Runes::Kanban when present, else derived from the sidecar todos (all
    # in Todo). Returns { source:, path:, header:, columns: } where columns
    # maps "todo"/"in_progress"/"done"/"blocked" to card hashes.
    def board_for(mission)
      mmd = File.join(root, "docs", "missions", "#{mission.id}.mmd")
      if File.file?(mmd) && kanban_available?
        parsed = Runes::Kanban.parse(File.read(mmd))
        {
          source: :file, path: mmd, header: parsed[:header],
          columns: parsed[:columns].transform_values { |tasks| tasks.map { |t| card(t.title, t.assignee, t.done, t.column) } }
        }
      else
        {
          source: :derived, path: nil, header: {},
          columns: {
            "todo" => Array(mission.todos).map { |t| card(todo_title(t), nil, false, "todo") },
            "in_progress" => [], "done" => [], "blocked" => []
          }
        }
      end
    end

    def mission_body(mission)
      File.read(mission.path)
    rescue StandardError
      ""
    end

    # --- write paths (slice 3, behind the token gate) -----------------------

    # Write an epic to docs/epics/E-<n>-<slug>.md, atomically, with the same
    # naming the dispatcher's write_artifact uses. The body is sanitized: size
    # cap, no CR, and a markdown heading is guaranteed so the listing's
    # heading_of finds a title.
    def write_epic(body)
      text = sanitize_body(body)
      dir = File.join(root, "docs", "epics")
      FileUtils.mkdir_p(dir)
      n = next_epic_number(dir)
      title = heading_of_text(text)
      path = File.join(dir, "E-#{n}-#{slugify(title)}.md")
      atomic_write(path, text)
      path
    end

    def epic_path(id)
      return nil unless id.to_s.match?(ID_RE) && !id.to_s.include?("..")

      path = File.join(root, "docs", "epics", "#{id}.md")
      File.file?(path) ? path : nil
    end

    # Move card `index` (global index across columns in STATUSES order) to
    # column `to` in the mission's .mmd, through the harness's Runes::Kanban
    # so the file stays valid for every other reader (agents, runes-kanban).
    # Creates the .mmd from the sidecar todos when the mission has none yet.
    # Returns { from:, to:, title:, path: } or { error: }.
    def move_card(mission, index:, to:)
      unless kanban_available?
        return { error: "harness Runes::Kanban is not on the load path" }
      end
      unless Runes::Kanban::STATUSES.include?(to)
        return { error: "unknown column #{to.inspect} (expected one of #{Runes::Kanban::STATUSES.join(', ')})" }
      end

      mmd = mmd_path(mission.id)
      unless File.file?(mmd)
        board = board_for(mission)
        text = Runes::Kanban.render(
          columns: board[:columns].transform_values { |cards| cards.map { |c| c[:title] } },
          mission: mission.title
        )
        atomic_write(mmd, text)
      end

      parsed = Runes::Kanban.parse(File.read(mmd))
      all = Runes::Kanban::STATUSES.flat_map { |c| parsed[:columns][c].map { |t| [c, t] } }
      entry = all[index]
      return { error: "no card at index #{index}" } unless entry

      from, task = entry
      return { error: "card is already in #{to}" } if from == to

      parsed[:columns][from].delete(task)
      task.column = to
      task.done = (to == "done")
      parsed[:columns][to] << task
      new_text = Runes::Kanban.render(columns: parsed[:columns], header: parsed[:header])
      errors = Runes::Kanban.validate(new_text)
      return { error: "rendered board failed validation: #{errors.join('; ')}" } if errors.any?

      atomic_write(mmd, new_text)
      { from: from, to: to, title: task.title, path: mmd }
    end

    # Append one JSONL line to the harness journal (the file JournalTail
    # reads), so a UI move is auditable next to the agents' own events.
    def append_journal(entry)
      configured = ENV.fetch("RUNES_OBSERVER_JOURNAL", "").strip
      return false if configured.casecmp("off").zero?

      path = configured.empty? ? File.join(harness_default_root, "log", "journal.jsonl") : configured
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(JSON.generate(entry.merge("at" => Time.current.utc.iso8601))) }
      true
    end

    # Tests point RUNES_OBSERVER_WORKSPACE at a tmpdir.
    def reset_cache!
      @root = nil
    end

    private

    def mmd_path(id)
      File.join(root, "docs", "missions", "#{id}.mmd")
    end

    def sanitize_body(body)
      text = body.to_s.gsub(/\r\n?/, "\n").strip
      raise Error, "epic body is empty" if text.empty?
      raise Error, "epic body exceeds #{MAX_EPIC_BYTES} bytes" if text.bytesize > MAX_EPIC_BYTES

      # Guarantee a markdown heading: without one the first line becomes it.
      unless text.start_with?("#")
        first, rest = text.split("\n", 2)
        text = "# #{first.strip}\n\n#{rest}"
      end
      text
    end

    def heading_of_text(text)
      text.each_line do |line|
        return line.sub(/\A#+\s*/, "").strip if line.start_with?("#")
      end
      "Untitled epic"
    end

    def next_epic_number(dir)
      existing = Dir.glob(File.join(dir, "E-*.md")).filter_map { |p| File.basename(p).match(/\AE-(\d+)-/)&.[](1)&.to_i }
      (existing.max || 0) + 1
    end

    def slugify(text)
      s = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 40].gsub(/-+\z/, "")
      s.empty? ? "untitled" : s
    end

    def atomic_write(path, content)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.open(tmp, "w") { |f| f.write(content) }
      File.rename(tmp, path)
    end

    def mission_for(path)
      id = File.basename(path, ".md")
      sidecar = {}
      json = File.join(File.dirname(path), "#{id}.json")
      if File.file?(json)
        begin
          sidecar = JSON.parse(File.read(json))
        rescue JSON::ParserError
          sidecar = {}
        end
      end
      Mission.new(
        id: id, path: path,
        title: sidecar["mission_title"].presence || heading_of(path),
        todos: sidecar["todos"] || [],
        source: sidecar["source"], source_path: sidecar["source_path"],
        mtime: File.mtime(path)
      )
    end

    def heading_of(path)
      File.foreach(path) do |line|
        return line.sub(/\A#+\s*/, "").strip if line.start_with?("#")
      end
      File.basename(path, ".md")
    rescue StandardError
      File.basename(path, ".md")
    end

    def todo_title(todo)
      todo.is_a?(Hash) ? (todo["title"] || todo[:title] || todo.to_s) : todo.to_s
    end

    def card(title, assignee, done, column)
      { title: title, assignee: assignee, done: done, column: column }
    end
  end
end
