# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module Runes
  # The pre-swarm discovery phase (docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md).
  #
  # Ruby owns the world state and the views; the model only fills typed
  # micro-task slots in fresh contexts; every claim is an anchor that Ruby
  # resolves mechanically. This module is the deterministic half: renderings
  # of one repo state, the loop detector, anchor resolution, and the
  # discovery.v1 / finding.v1 schema checks. Kernel-safe: no eval, no
  # dynamic define_method, stdlib only.
  module Discovery
    # ------------------------------------------------------------------ views
    #
    # Five deterministic renderings of one state_id (repo + sha + brief
    # hash). The model never reads the repo directly — only these.
    module Renderings
      TEST_RE = /(_test|spec|test_)\.rb\z|_spec\.rb\z|\/test\/|\/spec\//.freeze
      DOC_RE = /\A(README|CHANGELOG|CONTRIBUTING|ARCHITECTURE|DESIGN)/i.freeze
      IMPORT_RE = /^\s*(?:require|require_relative|import|from)\s+["']([^"']+)["']/m.freeze

      module_function

      # repo: path to a checkout. sha: commit sha (git rev-parse HEAD when
      # omitted). brief: the task brief, hashed into the state_id.
      def build(repo:, sha: nil, brief: '')
        repo = File.expand_path(repo)
        sha = sha || git(repo, 'rev-parse', 'HEAD')&.first || 'nogit'
        files = git(repo, 'ls-files') || Dir.glob(File.join(repo, '**', '*')).select { |f| File.file?(f) }.map { |f| f.delete_prefix("#{repo}/") }.sort
        files = files.map(&:strip).reject(&:empty?)
        {
          'state_id' => "repo:#{repo}:sha:#{sha}:brief:#{Digest::SHA256.hexdigest(brief.to_s)}",
          'sha' => sha,
          'tree' => tree_view(repo, files),
          'imports' => imports_view(repo, files),
          'tests' => files.select { |f| f.match?(TEST_RE) },
          'churn' => churn_view(repo),
          'docs' => files.select { |f| File.basename(f).match?(DOC_RE) }
        }
      end

      def tree_view(repo, files)
        files.each_with_object({}) do |f, out|
          dir = File.dirname(f)
          dir = '.' if dir == '.'
          (out[dir] ||= { 'files' => 0, 'loc' => 0 })
          out[dir]['files'] += 1
          out[dir]['loc'] += count_lines(File.join(repo, f))
        end
      end

      def imports_view(repo, files)
        files.select { |f| f.end_with?('.rb', '.py', '.ts', '.js') }.each_with_object({}) do |f, out|
          path = File.join(repo, f)
          content = begin
            File.read(path, 200_000)
          rescue StandardError
            nil
          end
          next if content.nil?

          out[f] = content.scan(IMPORT_RE).flatten.uniq
        end
      end

      def churn_view(repo)
        git(repo, 'log', '--pretty=%h %ad %s', '--date=short', '--since=90.days.ago', '-500') || []
      end

      def count_lines(path)
        File.foreach(path).count
      rescue StandardError
        0
      end

      def git(repo, *args)
        out = IO.popen(['git', '-C', repo, *args.map(&:to_s)], err: '/dev/null', &:read)
        return nil unless $?.success?

        out.lines.map(&:strip).reject(&:empty?)
      rescue StandardError
        nil
      end
    end

    # --------------------------------------------------------- loop detector
    #
    # §6: flag a repeated >=window-token window repeated >=repeats times.
    # Whitespace-tokenized, kernel-safe, no regex backtracking blowups.
    module LoopDetector
      WINDOW = 16
      REPEATS = 3

      module_function

      def loop_detected?(text, window: WINDOW, repeats: REPEATS)
        toks = text.to_s.split(/\s+/)
        return false if toks.size < window * repeats

        (0..(toks.size - window * repeats)).each do |i|
          w = toks[i, window]
          next if w.uniq.size < window / 2 # degenerate window

          count = 0
          j = i
          while toks[j, window] == w
            count += 1
            j += window
          end
          return true if count >= repeats
        end
        false
      end
    end

    # ------------------------------------------------------------- anchors
    #
    # An anchor is data, not prose: "path:start-end" or "path:symbol".
    # Resolution is mechanical: the file exists, the line range is inside
    # the file, and a symbol anchor matches a defined name in it.
    module Anchor
      ANCHOR_RE = %r{\A([\w./+-]+\.\w+):(\d+)(?:-(\d+))?\z}.freeze
      SYMBOL_RE = %r{\A([\w./+-]+\.\w+):([A-Za-z_][\w:?!]*)\z}.freeze
      DEFN_RE = /\b(?:def|class|module|fn|func|function|defn)\s+([A-Za-z_][\w:?!]*)/.freeze

      module_function

      def parse(text)
        t = text.to_s.strip
        if (m = t.match(ANCHOR_RE))
          { 'path' => m[1], 'start' => m[2].to_i, 'end' => (m[3] || m[2]).to_i }
        elsif (m = t.match(SYMBOL_RE))
          { 'path' => m[1], 'symbol' => m[2] }
        end
      end

      def resolved?(anchor, repo:)
        parsed = anchor.is_a?(Hash) ? anchor : parse(anchor)
        return false if parsed.nil?

        path = File.expand_path(parsed['path'], repo)
        return false unless path.start_with?(File.expand_path(repo)) && File.file?(path)

        if parsed['symbol']
          content = begin
            File.read(path, 1_000_000)
          rescue StandardError
            return false
          end
          return content.match?(DEFN_RE) && content.include?(parsed['symbol'])
        end

        lines = File.foreach(path).count
        parsed['start'] >= 1 && parsed['end'] <= lines
      rescue StandardError
        false
      end
    end

    # ------------------------------------------------------------- schemas
    #
    # finding.v1 and discovery.v1 validation — the same fail-loud discipline
    # as the envelope: a finding without a resolvable anchor is dropped at
    # verify, never reworded; guess confidence is quarantined.
    module Schemas
      FINDING_REQUIRED = %w[subproblem_id finding anchors confidence].freeze
      CONFIDENCES = %w[grounded partial guess].freeze
      CARD_REQUIRED = %w[state_id problem subproblems meta].freeze

      module_function

      def finding_errors(hash)
        return ['finding: not a Hash'] unless hash.is_a?(Hash)

        errs = FINDING_REQUIRED.reject { |k| hash.key?(k) }.map { |k| "finding: missing #{k}" }
        conf = hash['confidence'].to_s
        errs << "finding: unknown confidence #{conf.inspect}" unless CONFIDENCES.include?(conf)
        anchors = hash['anchors']
        errs << 'finding: anchors must be a non-empty list' unless anchors.is_a?(Array) && !anchors.empty?
        if hash['finding'].nil? && hash['unknown'].to_s.empty?
          errs << 'finding: either finding or unknown is required'
        end
        errs
      end

      def card_errors(hash)
        return ['card: not a Hash'] unless hash.is_a?(Hash)

        CARD_REQUIRED.reject { |k| hash.key?(k) }.map { |k| "card: missing #{k}" }
      end
    end

    # ------------------------------------------------------------ assembly
    #
    # Ruby assembles the card; the model only filled slots. Returns the
    # discovery.v1 hash and writes discovery.json + discovery_card.md.
    module Card
      module_function

      def assemble(state_id:, problem:, subproblems:, modules:, unknowns:, risks:,
                   mission_seed:, meta:, out_dir:)
        card = {
          'schema' => 'discovery.v1',
          'state_id' => state_id,
          'problem' => problem,
          'subproblems' => subproblems,
          'modules' => modules,
          'unknowns' => unknowns,
          'risks' => risks,
          'mission_seed' => mission_seed,
          'meta' => meta
        }
        errors = Schemas.card_errors(card)
        raise Error, "discovery card invalid: #{errors.join('; ')}" unless errors.empty?

        FileUtils.mkdir_p(out_dir)
        json_path = File.join(out_dir, 'discovery.json')
        md_path = File.join(out_dir, 'discovery_card.md')
        File.write(json_path, JSON.pretty_generate(card) + "\n")
        File.write(md_path, render_markdown(card))
        { 'card' => card, 'json_path' => json_path, 'md_path' => md_path }
      end

      def render_markdown(card)
        lines = []
        lines << "# Discovery card — #{card['state_id']}"
        lines << ''
        lines << "## Problem"
        lines << card['problem']['restatement'].to_s
        lines << ''
        lines << "Success criteria:"
        Array(card['problem']['success_criteria']).each { |c| lines << "- #{c}" }
        lines << ''
        lines << "Out of scope:"
        Array(card['problem']['out_of_scope']).each { |c| lines << "- #{c}" }
        lines << ''
        lines << "## Subproblems"
        Array(card['subproblems']).each do |sp|
          lines << "### #{sp['id']} — #{sp['status']}"
          lines << sp['question'].to_s
          Array(sp['findings']).each { |f| lines << "- #{f}" }
        end
        lines << ''
        lines << "## Unknowns"
        Array(card['unknowns']).each do |u|
          lines << "- #{u['question']} — probe: #{u['proposed_probe']}"
        end
        lines << ''
        lines << "## Risks"
        Array(card['risks']).each do |r|
          lines << "- #{r['risk']} (#{r['evidence_anchor']}) — #{r['mitigation']}"
        end
        lines << ''
        lines << "## Mission seed (a suggestion to /plan, not a plan)"
        Array(card['mission_seed']['proposed_todos']).each { |t| lines << "- #{t}" }
        lines << ''
        meta = card['meta'] || {}
        lines << "## Meta"
        lines << "- renderings: #{Array(meta['renderings_used']).join(', ')}"
        lines << "- calls: text=#{meta.dig('calls', 'text')} d1=#{meta.dig('calls', 'd1')}"
        lines << "- anchor_pass_rate: #{meta['anchor_pass_rate']}"
        lines << "- loop_events: #{meta['loop_events']}"
        lines << "- sufficiency: #{JSON.generate(meta['sufficiency'])}"
        lines.join("\n") + "\n"
      end
    end

    class Error < StandardError; end
  end
end
