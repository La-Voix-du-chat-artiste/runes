# frozen_string_literal: true

require "digest"
require "fileutils"

module Runes
  # Content-addressed documents.
  #
  # The layout is not invented here either: `<root>/ab/cd/<sha256>.<ext>`, two
  # shard levels, which is what `pipeline_prospect` publishes in its
  # `HARNESS.md` ("tout contenu (textarea ou upload) est stocké une seule fois,
  # adressé par son SHA-256"). The reference to a document is its full path, so
  # an agent's prompt, a report or a transcript can carry one without inventing
  # a filename — and two identical uploads are one file on disk.
  #
  # Why a library and not a new verb: Runes' selling point is that a workflow
  # file runs unmodified under Roast, whose verb set is exactly the seven runes.
  # A `ruby` step calling `Runes::DocStore.put` costs one line and keeps that
  # claim true; promoting it to a verb is a product decision, not a technical
  # one. See docs/DSL_POWER.md.
  class DocStore
    Error = Class.new(StandardError)

    # The extensions the pipeline itself uses; any sane token is accepted,
    # because refusing `.png` in a document store is a footgun, while accepting
    # `../evil` would be a path escape.
    EXTS = %w[txt md pdf json csv html].freeze
    EXT_TOKEN = /\A[a-z0-9]{1,8}\z/

    attr_reader :root

    def initialize(root:)
      @root = root.to_s
    end

    # Store a string; returns its address. Identical content is stored once.
    #
    # @param ext [String] file extension without the dot ("txt", "md", "pdf")
    # @return [Hash] { sha:, path:, bytes:, existed: }
    def put(content, ext: "txt")
      data = content.to_s
      store(data, normalize_ext(ext))
    end

    # Store a file from disk, keeping its extension unless told otherwise.
    def put_file(source, ext: nil)
      raise Error, "doc store: #{source} is not a file" unless File.file?(source)

      store(File.binread(source), normalize_ext(ext || File.extname(source).delete_prefix(".")))
    end

    # @return [String, nil] the path for a hash that is already stored
    def path_for(sha, ext: "txt")
      token = sha.to_s
      return nil unless token.match?(/\A[0-9a-f]{64}\z/)

      path = File.join(root, token[0, 2], token[2, 2], "#{token}.#{normalize_ext(ext)}")
      File.file?(path) ? path : nil
    end

    def read(sha, ext: "txt")
      path = path_for(sha, ext: ext)
      path && File.read(path)
    end

    def sha_of(content)
      Digest::SHA256.hexdigest(content.to_s)
    end

    # Everything on disk, newest-agnostic and cheap: the store is small and the
    # filesystem is the index (the same reasoning as the app's SQLite-as-cache).
    def entries
      Dir.glob(File.join(root, "*", "*", "*")).select { |path| File.file?(path) }.sort.map do |path|
        name = File.basename(path)
        sha, ext = name.split(".", 2)
        { sha: sha, ext: ext, path: path, bytes: File.size(path) }
      end
    end

    def size = entries.size

    private

    def store(data, ext)
      sha = sha_of(data)
      path = File.join(root, sha[0, 2], sha[2, 2], "#{sha}.#{ext}")
      existed = File.file?(path)
      unless existed
        FileUtils.mkdir_p(File.dirname(path))
        # Write-then-rename: a reader (or another workflow) never sees a
        # half-written document under a content address.
        tmp = "#{path}.tmp-#{Process.pid}"
        File.binwrite(tmp, data)
        File.rename(tmp, path)
      end
      { sha: sha, path: path, bytes: data.bytesize, existed: existed }
    end

    def normalize_ext(ext)
      value = ext.to_s.downcase.delete_prefix(".")
      unless value.match?(EXT_TOKEN)
        raise Error, "doc store: #{ext.inspect} is not a usable file extension " \
                     "(a lowercase token of up to 8 characters, e.g. #{EXTS.first(3).join(', ')})"
      end

      value
    end
  end
end
