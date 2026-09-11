# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/doc_store"
require_relative "../lib/runes/index"

# The data layer the pipeline workflow needs, matching the layout
# `pipeline_prospect` publishes: documents addressed by SHA-256, and `#E-001`
# style references resolved from the files themselves.
class DocStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("runes-docs-")
    @store = Runes::DocStore.new(root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir, true) if @dir && Dir.exist?(@dir)
  end

  def test_it_addresses_content_by_sha256_in_two_shards
    entry = @store.put("Bonjour", ext: "txt")

    assert_match(/\A[0-9a-f]{64}\z/, entry[:sha])
    assert_equal 7, entry[:bytes]
    refute entry[:existed]
    # ab/cd/<sha>.txt — their layout, so their tooling finds it
    assert_equal File.join(@dir, entry[:sha][0, 2], entry[:sha][2, 2], "#{entry[:sha]}.txt"), entry[:path]
    assert_equal "Bonjour", File.read(entry[:path])
  end

  def test_identical_content_is_stored_once
    first = @store.put("same bytes")
    second = @store.put("same bytes")

    assert_equal first[:sha], second[:sha]
    assert second[:existed], "the second put must report the file was already there"
    assert_equal 1, @store.size
  end

  def test_the_same_content_in_another_extension_is_another_document
    @store.put("x", ext: "txt")
    @store.put("x", ext: "md")

    assert_equal 2, @store.size
  end

  def test_it_reads_back_and_looks_up_by_hash
    entry = @store.put("contenu", ext: "md")

    assert_equal "contenu", @store.read(entry[:sha], ext: "md")
    assert_equal entry[:path], @store.path_for(entry[:sha], ext: "md")
    assert_nil @store.path_for("not-a-hash")
    assert_nil @store.path_for("a" * 64), "an unknown hash is nil, not an error"
  end

  def test_files_on_disk_can_be_stored_by_path
    source = File.join(@dir, "goal.md")
    File.write(source, "# Goal\n")

    entry = @store.put_file(source)

    assert_equal @store.sha_of(File.read(source)), entry[:sha]
    assert_equal "md", File.basename(entry[:path]).split(".", 2).last
  end

  def test_entries_lists_what_is_stored
    @store.put("one")
    @store.put("two", ext: "md")

    entries = @store.entries
    assert_equal 2, entries.size
    assert_equal %w[md txt], entries.map { |e| e[:ext] }.sort
    assert_operator entries.first[:bytes], :>, 0
  end

  # A document store that refuses `.png` is a footgun; one that accepts
  # `../evil` is an escape. The line is the token, not a whitelist.
  def test_an_extension_that_is_a_path_is_refused_but_an_unusual_one_is_fine
    assert_raises(Runes::DocStore::Error) { @store.put("x", ext: "../evil") }
    assert_raises(Runes::DocStore::Error) { @store.put("x", ext: "") }
    assert_raises(Runes::DocStore::Error) { @store.put("x", ext: "a" * 20) }

    entry = @store.put("PNG bytes here", ext: "png")
    assert_equal "png", File.basename(entry[:path]).split(".", 2).last
    assert_raises(Runes::DocStore::Error) { @store.put_file("/nope/nope.md") }
  end
end

class IndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("runes-index-")
    epic = File.join(@dir, "epics", "alpha_2026-09-11")
    other = File.join(@dir, "epics", "beta_2026-09-11")
    FileUtils.mkdir_p(File.join(epic, "missions"))
    FileUtils.mkdir_p(File.join(other, "missions"))
    File.write(File.join(epic, "goal.md"), "# Alpha\n\n<!-- code: E-001 -->\n\nDecliner #E-002 aussi.\n")
    File.write(File.join(other, "goal.md"), "# Beta\n\n<!-- code: E-002 -->\n")
    File.write(File.join(epic, "missions", "one.mmd"), "%% Code: M-001\n%% Mission: One\n\nkanban\n  Todo:\n")
    File.write(File.join(other, "missions", "two.mmd"), "%% Code: M-001\n%% Mission: Two\n\nkanban\n  Todo:\n")
    @index = Runes::Index.new(root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir, true) if @dir && Dir.exist?(@dir)
  end

  def test_it_finds_codes_in_headers_and_markers
    assert_equal %w[E-001 E-002 M-001], @index.codes.keys.sort
    assert_equal 1, @index.codes["E-001"].size
    assert_equal 2, @index.codes["M-001"].size, "mission codes are per-epic, so they repeat"
  end

  def test_a_reference_resolves_with_or_without_the_hash
    path = @index.resolve("#E-001")
    assert_equal File.join(@dir, "epics", "alpha_2026-09-11", "goal.md"), path
    assert_equal path, @index.resolve("E-001")
    assert_nil @index.resolve("#E-999")
    assert_nil @index.resolve("not a code")
  end

  # The ambiguity is real (mission codes are per-epic): where the reference was
  # written decides which one it means.
  def test_a_per_epic_code_resolves_inside_its_own_epic_when_the_caller_says_where
    from_beta = File.join(@dir, "epics", "beta_2026-09-11", "goal.md")
    from_alpha = File.join(@dir, "epics", "alpha_2026-09-11", "goal.md")

    assert_equal File.join(@dir, "epics", "beta_2026-09-11", "missions", "two.mmd"),
                 @index.resolve("#M-001", from: from_beta)
    assert_equal File.join(@dir, "epics", "alpha_2026-09-11", "missions", "one.mmd"),
                 @index.resolve("#M-001", from: from_alpha)
  end

  def test_references_and_link_report_what_does_not_resolve
    text = "Decliner #E-001 puis voir #E-404 et #M-001."

    assert_equal %w[E-001 E-404 M-001], @index.references(text)
    linked = @index.link(text)
    assert_equal %w[E-001 M-001], linked[:resolved].keys
    assert_equal %w[E-404], linked[:missing]
  end

  # A reference is delimited by punctuation, not by `\b`: at the end of a
  # Markdown emphasis the next character is `_`, which `\b` counts as a word
  # character. The weekly report wrote exactly that and silently lost a link.
  def test_a_reference_is_found_next_to_punctuation_and_emphasis
    assert_equal %w[E-001 M-001],
                 @index.references("_épic #E-001 · mission #M-001_")
    assert_equal %w[E-001], @index.references("(voir #E-001).")
    assert_equal %w[M-001], @index.references("voir #M-001, puis la suite")
    assert_empty @index.references("#E-12x is not a code")
    # 4 digits stay valid: `next_code` mints "%03d" and passes 999 one day.
    assert_equal %w[E-0012], @index.references("voir #E-0012 pour la suite")
  end
end
