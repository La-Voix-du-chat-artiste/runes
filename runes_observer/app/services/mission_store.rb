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

    # Tests point RUNES_OBSERVER_WORKSPACE at a tmpdir.
    def reset_cache!
      @root = nil
    end

    private

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
