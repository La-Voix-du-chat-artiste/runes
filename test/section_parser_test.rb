# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SectionParserTest < Minitest::Test
  def setup
    @parser = Runes::Core::SectionParser.new
  end

  def test_it_parses_hash_and_bold_section_headings
    text = <<~TEXT
      ### ANSWER
      La climatisation est réversible.

      **CITATIONS**
      Villa de Mer / Junior Suite / 032101
    TEXT

    parsed = @parser.parse(text)

    assert parsed[:had_sections]
    assert_equal "La climatisation est réversible.", parsed[:sections]["ANSWER"]
    assert_equal "Villa de Mer / Junior Suite / 032101", parsed[:sections]["CITATIONS"]
    assert_equal "La climatisation est réversible.", parsed[:answer]
    assert_equal ["Villa de Mer / Junior Suite / 032101"], parsed[:citations]
  end

  def test_it_parses_french_protocol_sections
    text = <<~TEXT
      REPONSE_CANDIDATE:
      La chambre supérieure n'est pas documentée.

      CITATIONS:
      Villa de Mer / Chambre Deluxe / 022901
    TEXT

    parsed = @parser.parse(text)

    assert_equal "La chambre supérieure n'est pas documentée.", parsed[:sections]["REPONSE_CANDIDATE"]
    assert_equal "La chambre supérieure n'est pas documentée.", parsed[:answer]
  end

  def test_it_does_not_split_inside_fenced_code
    text = <<~TEXT
      ### ANSWER
      Exemple :

      ```ruby
      ### ANSWER
      puts "not a heading"
      ```

      ### CITATIONS
      aucune
    TEXT

    parsed = @parser.parse(text)

    assert_equal 2, parsed[:sections].size
    assert_includes parsed[:sections]["ANSWER"], 'puts "not a heading"'
    assert_equal [], parsed[:citations]
  end

  def test_it_removes_thinking_blocks
    text = <<~TEXT
      <thinking>
      I should not be here.
      </thinking>
      ### ANSWER
      Réponse courte.
      ### CITATIONS
      aucune
    TEXT

    parsed = @parser.parse(text)

    refute_includes parsed[:answer], "I should not be here"
    assert_equal "Réponse courte.", parsed[:answer]
  end

  def test_it_falls_back_to_the_whole_body
    parsed = @parser.parse("Just an answer without headings.")

    refute parsed[:had_sections]
    assert_equal "Just an answer without headings.", parsed[:body]
    assert_equal "Just an answer without headings.", parsed[:answer]
    assert_equal [], parsed[:citations]
  end

  def test_it_finds_inline_citations
    parsed = @parser.parse("La réponse. Citations: Villa de Mer / Junior Suite / 032101")

    assert_equal ["Villa de Mer / Junior Suite / 032101"], parsed[:citations]
  end

  def test_it_splits_multiple_citations_on_semicolons_and_commas
    parsed = @parser.parse("ANSWER\nx\nCitations: Villa de Mer; Junior Suite, 032101")

    assert_equal ["Villa de Mer", "Junior Suite", "032101"], parsed[:citations]
  end

  def test_it_handles_aucune_citations
    parsed = @parser.parse("ANSWER\nJe ne sais pas.\nCitations: aucune")

    assert_equal [], parsed[:citations]
  end

  def test_it_reports_oversized_input_without_parsing
    parsed = @parser.parse("x" * (Runes::Core::SectionParser::MAX_INPUT_BYTES + 1))

    assert_equal :too_large, parsed[:error]
    assert_equal [], parsed[:citations]
    refute parsed[:had_sections]
  end
end
