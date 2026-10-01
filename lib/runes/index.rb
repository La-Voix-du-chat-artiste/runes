# frozen_string_literal: true

module Runes
  # Smart codes, resolved from the files themselves.
  #
  # `pipeline_prospect` lets a name reference another entity with `#E-001` /
  # `#M-001` and "l'app crée le lien automatiquement". Its app keeps that in
  # SQLite; on disk the files *are* the source of truth, so the index is a scan
  # and nothing needs syncing:
  #
  #   %% Code: M-001        (a mission kanban header)
  #   <!-- code: E-001 -->  (the marker this workflow writes into goal.md)
  #
  # Two properties matter and are easy to get wrong:
  #
  #   * **epic codes are global, mission codes are per-epic** (their rule), so a
  #     code can legitimately be ambiguous. `codes` therefore maps a code to
  #     *every* path that claims it, and `resolve` prefers one inside the same
  #     epic directory when the caller says where the reference was written.
  #   * an unresolved reference is reported, not invented: `link` returns
  #     `missing:` so a workflow can refuse to write prose that points nowhere.
  class Index
    CODE_PATTERN = /\A[A-Za-z]\d{0,3}-\d{1,4}\z/
    MARKER = /(?:%%\s*Code:|<!--\s*code:)\s*([A-Za-z]\d{0,3}-\d{1,4})/i

    def initialize(root:, globs: nil)
      @root = root.to_s
      @globs = globs || ["**/*.md", "**/*.mmd"]
    end

    # @return [Hash] code => [path, ...] (insertion order: as scanned)
    def codes
      scan unless @scanned
      @codes
    end

    def paths
      codes.values.flatten
    end

    # @param from [String, nil] the file the reference was written in, so a
    #   per-epic mission code resolves inside its own epic first
    def resolve(reference, from: nil)
      token = normalize(reference)
      return nil if token.nil?

      candidates = codes[token] || []
      return nil if candidates.empty?

      return candidates.first if from.nil?

      epic = epic_dir(from)
      candidates.find { |path| epic && path.start_with?(epic) } || candidates.first
    end

    # Every code mentioned in a text ("Décliner #E-001").
    #
    # The trailing boundary is "not followed by another code character", not
    # `\b`: a reference at the end of a Markdown emphasis (`#M-001_`) or before
    # a parenthesis is still a reference, and `\b` treats `_` as a word
    # character — which silently dropped exactly that case in the weekly report.
    def references(text)
      text.to_s.scan(/#([A-Za-z]\d{0,3}-\d{1,4})(?![A-Za-z0-9-])/).flatten.uniq
    end

    # Resolve every reference in a text: what it points at, and what it does not.
    def link(text, from: nil)
      refs = references(text)
      resolved = {}
      refs.each { |code| resolved[code] = resolve(code, from: from) }
      missing = []
      resolved.each { |code, path| missing << code if path.nil? }
      { resolved: resolved.reject { |_code, path| path.nil? }, missing: missing }
    end

    def reload!
      @scanned = false
      @codes = nil
      self
    end

    private

    def scan
      @scanned = true
      @codes = {}
      paths = []
      @globs.each { |glob| paths.concat(Dir.glob(File.join(@root, glob))) }
      paths.sort.each do |path|
        next unless File.file?(path)

        text = File.read(path)
        text.scan(MARKER).flatten.each do |code|
          (@codes[code.upcase] ||= []) << path
        end
      end
      @codes
    end

    def normalize(reference)
      token = reference.to_s.strip.sub(/\A#/, '').upcase
      token.match?(CODE_PATTERN) ? token : nil
    end

    def epic_dir(path)
      parts = File.expand_path(path.to_s).split(File::SEPARATOR)
      index = nil
      (parts.length - 1).downto(0) do |i|
        if parts[i].match?(/\A[A-Za-z0-9_]+_\d{4}-\d{2}-\d{2}\z/)
          index = i
          break
        end
      end
      index ? parts[0..index].join(File::SEPARATOR) : nil
    end
  end
end
