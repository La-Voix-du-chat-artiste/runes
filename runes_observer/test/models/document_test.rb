require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  test "valid document" do
    doc = Document.new(sha: "a" * 64, ext: "md", bytes: 12, name: "hello.md")
    assert doc.valid?
  end

  test "sha must be 64 lowercase hex" do
    assert_not Document.new(sha: "abc", ext: "md", bytes: 1, name: "x").valid?
    assert_not Document.new(sha: "A" * 64, ext: "md", bytes: 1, name: "x").valid?
    assert_not Document.new(sha: "../" + "a" * 62, ext: "md", bytes: 1, name: "x").valid?
  end

  test "ext must be whitelisted" do
    assert_not Document.new(sha: "a" * 64, ext: "exe", bytes: 1, name: "x").valid?
    assert_not Document.new(sha: "a" * 64, ext: "../../etc", bytes: 1, name: "x").valid?
  end

  test "sha is unique per ext but the same content can live under two extensions" do
    Document.create!(sha: "b" * 64, ext: "md", bytes: 3, name: "a.md")
    assert_not Document.new(sha: "b" * 64, ext: "md", bytes: 3, name: "b.md").valid?
    assert Document.new(sha: "b" * 64, ext: "txt", bytes: 3, name: "a.txt").valid?
  end
end
