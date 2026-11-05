# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class OrchestrationGuardsTest < Minitest::Test
  def setup
    @evidence = [
      {
        "tool" => "resolve_room",
        "args" => { "book" => "Villa de Mer", "chapter" => "Junior Suite" },
        "result" => {
          "status" => "resolved",
          "candidates" => [
            { "book" => "Villa de Mer", "chapter" => "Junior Suite", "code" => "032101" }
          ]
        }
      },
      {
        "tool" => "search_entries",
        "args" => {},
        "result" => {
          "citation_hints" => ["Villa de Mer / Junior Suite / 032101"],
          "results" => [
            {
              "description" => "La climatisation est réversible. Capacité 2 personnes.",
              "citation" => "Villa de Mer / Junior Suite / 032101"
            }
          ]
        }
      }
    ]
  end

  def guards(checks = {})
    Runes::Orchestration::Guards.new(task: "question", evidence: @evidence, checks: checks)
  end

  def codes(violations)
    violations.map(&:code)
  end

  def test_a_grounded_answer_with_a_citation_passes
    answer = "La climatisation est réversible. Capacité 2 personnes. Citations: Villa de Mer / Junior Suite / 032101"

    violations = guards(
      "must_cite" => ["Villa de Mer", "032101"],
      "must_match" => ["climatisation"],
      "must_not_match" => ["superficie"]
    ).check(answer)

    assert_empty violations.select(&:error?), codes(violations).inspect
  end

  def test_it_requires_must_cite_tokens_and_a_citations_line
    violations = guards("must_cite" => ["Villa de Mer"]).check("Une réponse sans citation.")

    assert_includes codes(violations), "citation_missing"
  end

  def test_it_rejects_an_unknown_citation
    violations = guards("must_cite" => ["Villa de Mer"]).check(
      "Une réponse. Citations: Château Inconnu / 999999"
    )

    assert_includes codes(violations), "citation_unknown"
  end

  def test_it_rejects_an_unresolved_room_without_abstention
    evidence = [
      {
        "tool" => "resolve_room",
        "result" => {
          "status" => "not_found",
          "candidates" => [{ "book" => "Villa de Mer", "chapter" => "Chambre Deluxe" }]
        }
      }
    ]
    guard = Runes::Orchestration::Guards.new(task: "q", evidence: evidence)

    violations = guard.check("La chambre supérieure mesure 30 m2. Citations: aucune")

    assert_includes codes(violations), "room_unresolved_asserted"
  end

  def test_it_accepts_an_unresolved_room_when_the_answer_abstains
    evidence = [
      {
        "tool" => "resolve_room",
        "result" => {
          "status" => "not_found",
          "candidates" => [{ "book" => "Villa de Mer", "chapter" => "Chambre Deluxe" }]
        }
      }
    ]
    guard = Runes::Orchestration::Guards.new(task: "q", evidence: evidence)

    violations = guard.check("La chambre supérieure n'est pas documentée. Citations: aucune")

    refute_includes codes(violations), "room_unresolved_asserted"
  end

  def test_it_rejects_forbidden_phrases_and_missing_required_phrases
    violations = guards(
      "must_match" => ["non documenté"],
      "must_not_match" => ["superficie"]
    ).check("La superficie est de 30 m2. Citations: aucune")

    assert_includes codes(violations), "phrase_missing"
    assert_includes codes(violations), "phrase_forbidden"
  end

  def test_it_warns_when_a_unit_number_is_not_grounded
    violations = guards.check("La chambre mesure 120 cm. Citations: aucune")

    assert_includes codes(violations), "number_ungrounded"
    assert violations.find { |v| v.code == "number_ungrounded" }.warn?
  end

  def test_it_rejects_empty_artifacts_and_raw_tool_calls
    assert_includes codes(guards.check("")), "artifact_missing"
    assert_includes codes(guards.check('{"tool":"search","args":{}}')), "artifact_invalid"
    assert_includes codes(guards.check("Citations: Villa de Mer")), "artifact_missing"
  end

  def test_it_rejects_truncation_receipts
    violations = guards.check("A complete-looking answer.", receipt: { finish_reason: "length", status: :ok })

    assert_includes codes(violations), "truncated"
  end

  def test_it_warns_when_a_long_answer_has_no_terminal_punctuation
    violations = guards.check("x" * 100)

    assert_includes codes(violations), "truncated_suspect"
    assert violations.find { |v| v.code == "truncated_suspect" }.warn?
  end

  def test_it_rejects_a_repair_that_did_not_change_the_artifact
    answer = "Une réponse stable. Citations: aucune"
    sha = Runes::SHA256.hex(answer)

    violations = guards.check(answer, receipt: { previous_sha: sha, artifact_sha: sha })

    assert_includes codes(violations), "no_progress"
  end
end
