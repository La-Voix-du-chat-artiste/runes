require "test_helper"
require "tmpdir"

class DocStoreServiceTest < ActiveSupport::TestCase
  setup do
    @tmp = Dir.mktmpdir("runes-docstore")
    @old = ENV["RUNES_OBSERVER_DOCSTORE"]
    ENV["RUNES_OBSERVER_DOCSTORE"] = @tmp
    DocStoreService.reset_cache!
  end

  teardown do
    ENV["RUNES_OBSERVER_DOCSTORE"] = @old
    DocStoreService.reset_cache!
    FileUtils.remove_entry(@tmp)
  end

  test "put_string stores content-addressed and upserts the row" do
    doc = DocStoreService.put_string("# hi\n", ext: "md", name: "hello.md", uploaded_by: "tester")

    assert_equal 64, doc.sha.length
    assert_equal "md", doc.ext
    assert_equal 5, doc.bytes
    assert_equal "tester", doc.uploaded_by
    assert File.file?(File.join(@tmp, doc.sha[0, 2], doc.sha[2, 2], "#{doc.sha}.md"))
    assert_equal "# hi\n", File.read(DocStoreService.path_for(doc.sha, ext: "md"))
  end

  test "identical content is stored once and the row is reused" do
    first = DocStoreService.put_string("same", ext: "txt", name: "one.txt")
    second = DocStoreService.put_string("same", ext: "txt", name: "two.txt")

    assert_equal first.sha, second.sha
    assert_equal first.id, second.id
    assert_equal "two.txt", second.reload.name
    assert_equal 1, Document.where(sha: first.sha).count
  end

  test "path_for re-validates and refuses traversal shapes" do
    doc = DocStoreService.put_string("x", ext: "txt", name: "x.txt")

    assert_nil DocStoreService.path_for("../" + "a" * 62, ext: "txt")
    assert_nil DocStoreService.path_for(doc.sha, ext: "exe")
    assert_nil DocStoreService.path_for("z" * 64, ext: "txt")
    assert_equal doc.sha, File.basename(DocStoreService.path_for(doc.sha, ext: "txt"), ".txt")
  end

  test "put_upload reads an uploaded file and derives the extension" do
    upload = ActionDispatch::Http::UploadedFile.new(
      tempfile: StringIO.new("payload"), filename: "report.md", type: "text/markdown"
    )
    doc = DocStoreService.put_upload(upload)

    assert_equal "md", doc.ext
    assert_equal "report.md", doc.name
    assert_equal "payload", File.read(DocStoreService.path_for(doc.sha, ext: "md"))
  end

  test "put_upload refuses unsupported extensions and oversize content" do
    bad = ActionDispatch::Http::UploadedFile.new(
      tempfile: StringIO.new("MZ"), filename: "virus.exe", type: "application/octet-stream"
    )
    assert_raises(DocStoreService::Error) { DocStoreService.put_upload(bad) }

    big = ActionDispatch::Http::UploadedFile.new(
      tempfile: StringIO.new("x" * (DocStoreService::MAX_BYTES + 1)), filename: "big.txt"
    )
    assert_raises(DocStoreService::Error) { DocStoreService.put_upload(big) }
  end

  test "validators" do
    assert DocStoreService.valid_sha?("a" * 64)
    assert_not DocStoreService.valid_sha?("a" * 63)
    assert DocStoreService.valid_ext?("pdf")
    assert_not DocStoreService.valid_ext?("sh")
    assert DocStoreService.previewable?("md")
    assert_not DocStoreService.previewable?("pdf")
    assert_equal "text/markdown", DocStoreService.content_type("md")
  end
end
