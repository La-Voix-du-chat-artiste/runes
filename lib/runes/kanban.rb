# frozen_string_literal: true

require_relative 'compat'

module Runes
  # A mission's Kanban, as the Mermaid `.mmd` file a human, an agent or an app
  # can read (and edit).
  #
  # The format is not invented here: it is the contract `pipeline_prospect`
  # already publishes in its `HARNESS.md`, and the whole point of matching it
  # byte-for-byte is that the same file works in three places —
  #
  #   * a workflow writes and advances it (this class),
  #   * an external harness edits it with `$EDITOR`,
  #   * the Rails app syncs its index from it.
  #
  #   %% Code: M-001
  #   %% Mission: Contacter 10 prospects
  #   %% Épic: Lancement Produit Alpha (E-001)
  #   %% Créé le: 2026-09-08
  #   %% Statut: In Progress
  #
  #   kanban
  #     Todo:
  #       - [ ] Appeler Jean Dupont (Assigné: Jean Dupont)
  #     In Progress:
  #     Done:
  #       - [x] Identifier les 10 prospects
  #     Blocked:
  #
  # `render` -> `parse` is lossless for everything the grammar defines, and
  # `validate` is the same check their `scripts/harness/validate_mermaid.rb`
  # runs, so a workflow cannot write a file their validator rejects.
  module Kanban
    class Error < StandardError; end

    COLUMNS = {
      "todo" => "Todo",
      "in_progress" => "In Progress",
      "done" => "Done",
      "blocked" => "Blocked"
    }.freeze
    COLUMN_TO_STATUS = COLUMNS.invert.freeze
    STATUSES = COLUMNS.keys.freeze

    HEADER_FIELDS = {
      "code" => "Code",
      "mission" => "Mission",
      "epic" => "Épic",
      "created_at" => "Créé le",
      "status" => "Statut"
    }.freeze

    # The one place a title becomes a line. Model output arrives here, so it is
    # sanitised rather than trusted: a newline, a forged checkbox, a leading
    # list marker or a literal "(Assigné: …)" would otherwise restructure the
    # file a human and another app read.
    TITLE_LIMIT = 160

    # Plain class (no keyword_init Struct) to stay inside the kernel subset.
    # Free text after the assignee suffix is preserved verbatim (it is how a
    # verdict reason survives a round-trip; see #advance).
    class Task
      attr_accessor :title, :assignee, :done, :column

      def initialize(title, assignee = nil, done = false, column = 'todo')
        # Kwargs-compat shim for callers that predate the positional
        # constructor (title:/assignee:/done:/column: arrive as one Hash).
        if title.is_a?(Hash)
          h = title
          title = h[:title]
          assignee = h[:assignee]
          done = h[:done] || false
          column = h[:column] || 'todo'
        end
        @title = title
        @assignee = assignee
        @done = done
        @column = column
      end

      def line
        text = "    - [#{done ? 'x' : ' '}] #{title}"
        text += " (Assigné: #{assignee})" if assignee
        text
      end
    end

    class << self
      # @return [Hash] { header: {...}, columns: { "todo" => [Task], ... } }
      def parse(text)
        header = {}
        columns = STATUSES.to_h { |status| [status, []] }
        current = "todo"

        text.to_s.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          if (match = stripped.match(/\A%{1,2}\s*([^:]+):\s*(.*)\z/))
            key = HEADER_FIELDS.key(match[1].strip)
            header[key] = match[2].strip if key
            next
          end

          next if stripped == "kanban"

          if (match = stripped.match(/\A(.+):\z/)) && COLUMN_TO_STATUS.key?(match[1].strip)
            current = COLUMN_TO_STATUS.fetch(match[1].strip)
            next
          end

          next unless (match = stripped.match(/\A-\s*\[([ xX])\]\s*(.+?)\s*\z/))

          title, assignee = split_assignee(match[2])
          columns[current] << Task.new(title, assignee, match[1].downcase == 'x', current)
        end

        { header: header, columns: columns }
      end

      # @param mission [String] the mission title
      # @param columns [Hash] "todo" => [Task or Hash or String], ...
      # `header:` is what #parse returned, so `render(**parse(text))` is a
      # round-trip; explicit keywords win over it.
      def render(columns:, mission: nil, header: nil, code: nil, epic: nil,
                 created_at: nil, status: nil)
        parsed_header = header || {}
        columns = normalize_columns(columns)
        # Precedence: an explicit `status:` (a caller's decision) > the header we
        # were given (an app or a human owns it) > what the tasks imply.
        status ||= parsed_header["status"]
        status_key = status.nil? ? derive_status(columns) : normalize_column(status)
        out = {
          "code" => code || parsed_header["code"],
          "mission" => mission || parsed_header["mission"],
          "epic" => epic || parsed_header["epic"],
          "created_at" => (created_at || parsed_header["created_at"] || Runes::Compat.utc_date).to_s,
          "status" => COLUMNS.fetch(status_key)
        }

        lines = HEADER_FIELDS.filter_map do |key, label|
          value = out[key]
          value = value.to_s.gsub(/[\r\n]+/, " ").squeeze(" ").strip unless key == "created_at"
          "%% #{label}: #{value}" unless value.nil? || value.to_s.empty?
        end
        lines << ""
        lines << "kanban"
        STATUSES.each do |column|
          lines << "  #{COLUMNS.fetch(column)}:"
          columns.fetch(column).each { |task| lines << task.line }
        end
        lines.join("\n") << "\n"
      end

      # The same rules as their scripts/harness/validate_mermaid.rb, so a
      # workflow cannot write a file their tooling rejects.
      def validate(text)
        errors = []
        saw_kanban = false
        column = nil
        text.to_s.each_line.with_index(1) do |line, number|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("%")

          if stripped == "kanban"
            errors << "line #{number}: kanban must appear exactly once" if saw_kanban
            saw_kanban = true
            next
          end

          if (match = stripped.match(/\A(.+):\z/))
            name = match[1].strip
            if COLUMN_TO_STATUS.key?(name)
              column = name
              next
            end

            errors << "line #{number}: unknown column #{name.inspect} " \
                      "(allowed: #{COLUMNS.values.join(', ')})"
            next
          end

          next if stripped.match?(/\A-\s*\[([ xX])\]\s*\S/)

          errors << "line #{number}: not a task line: #{stripped.inspect}"
        end
        errors << "missing the `kanban` block" unless saw_kanban
        errors << "no kanban columns found" if saw_kanban && column.nil?
        errors
      end

      # Move a task, optionally recording why. Returns the new text.
      #
      # `to:` takes a status key ("done", "blocked") or the display name
      # ("Done", "In Progress"). The note is appended to the task text after the
      # assignee suffix, which is the one place the contract allows free text —
      # so the reason a task was blocked survives the round-trip.
      def advance(text, title:, to:, note: nil)
        parsed = parse(text)
        task = find_task(parsed, title)
        raise Error, "kanban: no task matching #{title.inspect}" if task.nil?

        destination = normalize_column(to)
        parsed[:columns].fetch(task.column).delete(task)
        task.column = destination
        task.done = destination == "done"
        task.title = "#{task.title} — #{note}" if note && !note.to_s.strip.empty?
        parsed[:columns].fetch(destination) << task
        render_parsed(parsed, rederive: true)
      end

      # Append a task to a column ("todo" by default).
      def add(text, title:, column: "todo", assignee: nil)
        parsed = parse(text)
        destination = normalize_column(column)
        parsed[:columns].fetch(destination) << Task.new(title, assignee, destination == "done", destination)
        render_parsed(parsed, rederive: true)
      end

      # Read-modify-write under an exclusive lock.
      #
      # The mission file is shared: a workflow, a human in `$EDITOR` and the app
      # that syncs from it all hold the same file. `pipeline_prospect` learned
      # this the hard way (two rotators clobbered each other's archive); the same
      # rule applies here, so every mutation takes `flock` for the whole
      # read-modify-write and writes in place rather than truncating first.
      def update_file(path)
        # Opening with CREAT would leave an empty mission behind when the caller
        # has the path wrong — a file that then validates as "no columns" and
        # reads like a bug in the app. Refuse instead.
        raise Error, "kanban: #{path} does not exist" unless File.file?(path)

        Runes::Compat.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR) do |file|
          file.flock(File::LOCK_EX)
          begin
            file.rewind
            updated = yield(file.read)
            file.rewind
            file.write(updated)
            file.truncate(file.pos)
            file.flush
            updated
          ensure
            file.flock(File::LOCK_UN)
          end
        end
      end

      def advance_file(path, title:, to:, note: nil)
        update_file(path) { |text| advance(text, title: title, to: to, note: note) }
      end

      def add_file(path, title:, column: "todo", assignee: nil)
        update_file(path) { |text| add(text, title: title, column: column, assignee: assignee) }
      end

      # A fresh file (no read-modify-write to protect).
      def write(path, text)
        Runes::Compat.mkdir_p(File.dirname(path))
        File.write(path, text)
        path
      end

      # The next free `#E-001` / `#M-001` style code, given the texts already in
      # the pipeline. Their app mints codes the same way, and the code is what
      # lets one entity reference another by name in free text (`"Décliner
      # #E-001"`).
      def next_code(existing_texts, prefix: "E")
        highest = 0
        Array(existing_texts).each do |text|
          match = text.to_s.match(/\b#{Regexp.escape(prefix)}-(\d+)\b/)
          candidate = match ? match[1].to_i : 0
          highest = candidate if candidate > highest
        end
        prefix.to_s + '-' + Runes::Compat.pad_left((highest + 1).to_s, 3)
      end

      # `M-001` in a header, `#M-001` in prose: the app resolves the latter.
      def reference(code)
        "##{code}"
      end

      def tasks(text, column: nil)
        columns = parse(text)[:columns]
        column ? columns.fetch(column.to_s, []) : columns.values.flatten
      end

      private

      def render_parsed(parsed, rederive: false)
        args = parsed.dup
        args[:status] = derive_status(normalize_columns(args[:columns])) if rederive
        render(**args)
      end

      def normalize_column(to)
        value = to.to_s
        return value if STATUSES.include?(value)

        COLUMN_TO_STATUS[value] ||
          STATUSES.find { |status| COLUMNS.fetch(status).casecmp?(value) } ||
          raise(Error, "kanban: unknown column #{value.inspect} " \
                       "(allowed: #{COLUMNS.values.join(', ')})")
      end

      def normalize_columns(columns)
        STATUSES.to_h do |column|
          list = Array(columns[column] || columns[COLUMNS.fetch(column)] || columns[column.to_sym])
          [column, list.map { |entry| coerce_task(entry, column) }]
        end
      end

      def coerce_task(entry, column)
        task = case entry
               when Task then entry
               when String then Task.new(entry, nil, column == "done", column)
               when Hash
                 done = entry.key?(:done) ? entry[:done] : column == "done"
                 Task.new(entry[:title] || entry["title"],
                          entry[:assignee] || entry["assignee"],
                          done,
                          column)
               else
                 raise Error, "kanban: cannot render a #{entry.class} as a task"
               end

        task.title = sanitize(task.title)
        task.assignee = sanitize(task.assignee, limit: 80) if task.assignee
        task
      end

      # Model output becomes a file line: collapse it to one line, refuse to let
      # it forge a checkbox or an assignee suffix, and bound its length. An empty
      # title is a programming error, not a task.
      def sanitize(text, limit: TITLE_LIMIT)
        value = text.to_s.gsub(/[\r\n\t]+/, " ")
                    .gsub(/\(Assigné\s*:/i, "(")
                    .squeeze(" ").strip
        value = value.sub(/\A[-*+]\s+/, "").sub(/\A\[[ xX]\]\s*/, "").strip
        value = "#{value.byteslice(0, limit).to_s.scrub}…" if value.bytesize > limit
        raise Error, "kanban: a task title cannot be empty" if value.empty?

        value
      end

      # The mission's status follows its tasks: someone has to be able to see
      # at a glance whether anything is left.
      def derive_status(columns)
        return "done" if columns.values.flatten.all? { |v| v.done } && columns.values.flatten.any?
        return "blocked" if columns.fetch("blocked").any?
        return "in_progress" if columns.fetch("in_progress").any? || columns.fetch("done").any?

        "todo"
      end

      def find_task(parsed, title)
        parsed[:columns].each_value do |list|
          found = list.find { |task| task.title == title || task.title.start_with?("#{title} —") }
          return found if found
        end
        nil
      end

      def split_assignee(raw)
        if (match = raw.match(/\A(.*?)\s*\(Assigné:\s*(.+?)\)\s*\z/))
          [match[1].strip, match[2].strip]
        else
          [raw.strip, nil]
        end
      end
    end
  end
end
