# frozen_string_literal: true

# The observer's handle on the harness's content-addressed document store
# (lib/runes/doc_store.rb): uploads land in `<root>/ab/cd/<sha256>.<ext>`,
# identical content is stored once, and the address of a document is its
# hash — which is what lets a packet payload reference one.
#
# Root resolution: `RUNES_OBSERVER_DOCSTORE` when set, else `<harness>/docs/store`
# (the harness root is derived from the same load path the transport
# initializer uses). The harness is required lazily-guarded: the web UI must
# boot without it, and only upload/serve raise when it is missing.
begin
  require "runes/doc_store"
rescue LoadError
  # Handled at call time: store_available? is false and callers get a clear
  # Error instead of a boot failure.
end

class DocStoreService
  Error = Class.new(StandardError)

  MAX_BYTES = 5 * 1024 * 1024
  SHA_RE = /\A[0-9a-f]{64}\z/
  # Extensions we render inline in the browser (html is served sandboxed —
  # see DocumentsController#serve); everything else downloads.
  PREVIEWABLE = %w[txt md json csv html].freeze
  CONTENT_TYPES = {
    "txt" => "text/plain", "md" => "text/markdown", "json" => "application/json",
    "csv" => "text/csv", "html" => "text/html", "pdf" => "application/pdf"
  }.freeze

  class << self
    def root
      @root ||= begin
        explicit = ENV.fetch("RUNES_OBSERVER_DOCSTORE", "").strip
        base = explicit.empty? ? File.join(harness_root, "docs", "store") : explicit
        FileUtils.mkdir_p(base)
        base
      end
    end

    def harness_root
      lib = ENV.fetch("RUNES_HARNESS_LIB") { File.expand_path("../../../lib", __dir__) }
      File.dirname(lib)
    end

    def store
      raise Error, "doc store: harness Runes::DocStore is not on the load path" unless defined?(Runes::DocStore)
      @store ||= Runes::DocStore.new(root: root)
    end

    def store_available?
      defined?(Runes::DocStore) ? true : false
    end

    def valid_sha?(sha)
      sha.to_s.match?(SHA_RE)
    end

    def valid_ext?(ext)
      Document::EXTS.include?(ext.to_s)
    end

    def previewable?(ext)
      PREVIEWABLE.include?(ext.to_s)
    end

    def content_type(ext)
      CONTENT_TYPES.fetch(ext.to_s, "application/octet-stream")
    end

    # Store an uploaded file (ActionDispatch::Http::UploadedFile or anything
    # responding to #read) and upsert the Document row. Returns the Document.
    def put_upload(upload, name: nil, uploaded_by: nil)
      content = upload.read
      raise Error, "doc store: upload exceeds #{MAX_BYTES} bytes" if content.bytesize > MAX_BYTES

      original = name.presence || (upload.respond_to?(:original_filename) ? upload.original_filename : nil).to_s
      ext = File.extname(original).sub(/\A\./, "").downcase
      ext = "txt" if ext.empty?
      raise Error, "doc store: unsupported extension .#{ext}" unless valid_ext?(ext)

      put_string(content, ext: ext, name: original.presence || "document.#{ext}", uploaded_by: uploaded_by)
    end

    def put_string(content, ext:, name:, uploaded_by: nil)
      raise Error, "doc store: unsupported extension .#{ext}" unless valid_ext?(ext)
      result = store.put(content, ext: ext)
      doc = Document.find_or_initialize_by(sha: result[:sha], ext: ext)
      doc.assign_attributes(bytes: result[:bytes], name: name, uploaded_by: uploaded_by)
      doc.save!
      doc
    end

    # The on-disk path for a stored hash — re-validated here even though the
    # store validates too: the controller must not trust a DB row or a URL
    # parameter when handing a path to send_file.
    def path_for(sha, ext:)
      return nil unless valid_sha?(sha) && valid_ext?(ext)
      store.path_for(sha, ext: ext)
    end

    # Tests point RUNES_OBSERVER_DOCSTORE at a tmpdir.
    def reset_cache!
      @root = nil
      @store = nil
    end
  end
end
