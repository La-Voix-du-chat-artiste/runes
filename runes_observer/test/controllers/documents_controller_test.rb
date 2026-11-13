require "test_helper"
require "tmpdir"

# Workspace slice 2A: upload → content-addressed store + Document row +
# runes/docs/added announcement; serve re-validates the address.
class DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Dir.mktmpdir("runes-docstore")
    @old_store = ENV["RUNES_OBSERVER_DOCSTORE"]
    @old_publish = ENV["RUNES_OBSERVER_PUBLISH"]
    ENV["RUNES_OBSERVER_DOCSTORE"] = @tmp
    ENV["RUNES_OBSERVER_PUBLISH"] = "off"
    DocStoreService.reset_cache!
  end

  teardown do
    ENV["RUNES_OBSERVER_DOCSTORE"] = @old_store
    ENV["RUNES_OBSERVER_PUBLISH"] = @old_publish
    DocStoreService.reset_cache!
    FileUtils.remove_entry(@tmp)
  end

  test "index lists documents and the upload form" do
    DocStoreService.put_string("# hi\n", ext: "md", name: "hello.md", uploaded_by: "tester")

    get documents_path

    assert_response :success
    assert_match "Documents", response.body
    assert_match "hello.md", response.body
    assert_match "Upload", response.body
  end

  test "upload stores the file, creates the row and redirects" do
    assert_difference "Document.count", 1 do
      post documents_path, params: {
        file: fixture_file_upload("hello.md", "text/markdown"),
        uploaded_by: "operator"
      }
    end

    assert_redirected_to documents_path
    doc = Document.last
    assert_equal "md", doc.ext
    assert_equal "hello.md", doc.name
    assert_equal "operator", doc.uploaded_by
    assert File.file?(DocStoreService.path_for(doc.sha, ext: "md"))
  end

  test "upload without a file is refused with an alert" do
    assert_no_difference "Document.count" do
      post documents_path, params: {}
    end
    assert_redirected_to documents_path
    assert_match "Choose a file", flash[:alert]
  end

  test "serve returns the stored bytes inline for text" do
    doc = DocStoreService.put_string("# hi\n", ext: "md", name: "hello.md")

    get document_path(sha: doc.sha, ext: "md")

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_match "# hi", response.body
  end

  test "serve downloads pdf as attachment" do
    doc = DocStoreService.put_string("%PDF-1.4 fake", ext: "pdf", name: "doc.pdf")

    get document_path(sha: doc.sha, ext: "pdf")

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
  end

  test "serve sandboxes uploaded html" do
    doc = DocStoreService.put_string("<script>alert(1)</script>", ext: "html", name: "x.html")

    get document_path(sha: doc.sha, ext: "html")

    assert_response :success
    assert_equal "sandbox", response.headers["Content-Security-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "serve refuses malformed addresses, unknown hashes and bad extensions" do
    doc = DocStoreService.put_string("x", ext: "txt", name: "x.txt")

    get document_path(sha: ".." + "a" * 62, ext: "txt")
    assert_response :not_found

    get document_path(sha: "a" * 64, ext: "exe")
    assert_response :not_found

    get document_path(sha: "z" * 64, ext: "txt")
    assert_response :not_found

    # A valid address with the wrong extension is a different document.
    get document_path(sha: doc.sha, ext: "md")
    assert_response :not_found
  end

  test "a packet payload referencing a stored sha links the document" do
    doc = DocStoreService.put_string("# hi\n", ext: "md", name: "hello.md")
    packet = Packet.create!(
      topic: "runes/prompts/req-doc/progress", kind: "progress", request_id: "req-doc",
      payload: JSON.generate("event" => "step_start", "doc" => doc.sha),
      payload_bytes: 60, occurred_at: 1.minute.ago, received_at: 1.minute.ago
    )

    get packet_path(packet)

    assert_response :success
    assert_match "documents", response.body
    assert_match "hello.md", response.body
    assert_match document_path(sha: doc.sha, ext: "md"), response.body
  end
end
