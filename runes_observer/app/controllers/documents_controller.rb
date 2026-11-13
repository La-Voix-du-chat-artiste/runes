# Workspace slice 2A (docs/WORKSPACE_PLAN.md): documents uploaded into the
# harness's content-addressed store. Upload records the Document row and
# announces it on the fabric (`runes/docs/added`) so the feed and the agents
# see it; serving re-validates the sha+ext pair before handing a path to
# send_file — the URL is user input, never a trusted address.
class DocumentsController < ApplicationController
  def index
    @documents = Document.recent.limit(100).to_a
    @store_root = DocStoreService.root
    @store_available = DocStoreService.store_available?
  end

  def create
    upload = params[:file]
    if upload.nil?
      redirect_to documents_path, alert: "Choose a file to upload." and return
    end

    begin
      doc = DocStoreService.put_upload(upload,
                                       name: params[:name].presence,
                                       uploaded_by: params[:uploaded_by].presence)
    rescue DocStoreService::Error => e
      redirect_to documents_path, alert: e.message and return
    end

    FabricPublisher.publish("runes/docs/added", {
      "sha" => doc.sha, "ext" => doc.ext, "bytes" => doc.bytes,
      "name" => doc.name, "uploaded_by" => doc.uploaded_by,
      "at" => Time.current.utc.iso8601
    })
    redirect_to documents_path, notice: "Stored #{doc.name} — #{doc.short_sha}…"
  end

  # GET /documents/:sha.:ext — the address IS the URL. Both segments are
  # re-validated (64-hex sha, whitelisted ext) before the store is asked for
  # a path, so `../` or a forged extension can never escape the store root.
  def serve
    sha = params[:sha].to_s
    ext = params[:ext].to_s
    unless DocStoreService.valid_sha?(sha) && DocStoreService.valid_ext?(ext)
      head :not_found and return
    end

    path = DocStoreService.path_for(sha, ext: ext)
    head :not_found and return unless path

    doc = Document.find_by(sha: sha, ext: ext)
    response.headers["X-Content-Type-Options"] = "nosniff"
    # Uploaded HTML is rendered sandboxed: opaque origin, no scripts, no
    # same-origin access — it is a preview, not a page we host.
    if ext == "html"
      response.headers["Content-Security-Policy"] = "sandbox"
    end
    send_file path,
              filename: doc&.name.presence || "#{sha[0, 12]}.#{ext}",
              type: DocStoreService.content_type(ext),
              disposition: DocStoreService.previewable?(ext) ? :inline : :attachment
  end
end
