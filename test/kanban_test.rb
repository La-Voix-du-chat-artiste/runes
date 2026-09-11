# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/kanban"

# The Kanban format is the contract between a Runes workflow, an external
# harness with `$EDITOR`, and `pipeline_prospect`'s Rails index. The fixture
# below is that project's own `HARNESS.md` sample, verbatim: if this test ever
# fails, we have stopped writing files their tooling can read.
class KanbanTest < Minitest::Test
  SAMPLE = <<~MMD
    %% Code: M-001
    %% Mission: Contacter 10 prospects
    %% Épic: Lancement Produit Alpha (E-001)
    %% Créé le: 2026-09-08
    %% Statut: In Progress

    kanban
      Todo:
        - [ ] Appeler Jean Dupont (Assigné: Jean Dupont)
        - [ ] Envoyer un email à Marie Martin (Assigné: Marie Martin)
      In Progress:
        - [ ] Préparer le script d'appel
      Done:
        - [x] Identifier les 10 prospects
      Blocked:
        - [ ] Valider le budget marketing
  MMD

  def test_it_parses_the_foreign_format
    parsed = Runes::Kanban.parse(SAMPLE)

    assert_equal "M-001", parsed[:header]["code"]
    assert_equal "Contacter 10 prospects", parsed[:header]["mission"]
    assert_equal "Lancement Produit Alpha (E-001)", parsed[:header]["epic"]
    assert_equal "2026-09-08", parsed[:header]["created_at"]
    assert_equal "In Progress", parsed[:header]["status"]
    assert_equal ["Appeler Jean Dupont", "Envoyer un email à Marie Martin"],
                 parsed[:columns]["todo"].map(&:title)
    assert_equal "Jean Dupont", parsed[:columns]["todo"].first.assignee
    assert parsed[:columns]["done"].first.done
    assert_equal ["Valider le budget marketing"], parsed[:columns]["blocked"].map(&:title)
  end

  def test_parse_render_is_lossless_for_their_sample
    assert_equal SAMPLE, Runes::Kanban.render(**Runes::Kanban.parse(SAMPLE))
  end

  # Their scripts/harness/validate_mermaid.rb is the arbiter: a workflow must
  # not be able to write something it rejects.
  def test_the_foreign_sample_validates_clean
    assert_empty Runes::Kanban.validate(SAMPLE)
  end

  def test_the_validator_rejects_what_their_tooling_rejects
    refute_empty Runes::Kanban.validate("kanban\n  Nowhere:\n    - [ ] x\n")
    refute_empty Runes::Kanban.validate("kanban\n  Todo:\n    - a task without a checkbox\n")
    refute_empty Runes::Kanban.validate("Todo:\n  - [ ] x\n")
    refute_empty Runes::Kanban.validate("kanban\n")
  end

  # --- the workflow's operations -------------------------------------------

  def test_advancing_a_task_moves_it_and_keeps_the_reason
    moved = Runes::Kanban.advance(SAMPLE, title: "Préparer le script d'appel",
                                         to: "done", note: "pass: script written")

    parsed = Runes::Kanban.parse(moved)
    assert_empty parsed[:columns]["in_progress"]
    task = parsed[:columns]["done"].find { |t| t.title.start_with?("Préparer le script") }
    refute_nil task
    assert task.done
    assert_includes task.title, "pass: script written"
    assert_empty Runes::Kanban.validate(moved)
  end

  def test_advancing_accepts_either_a_status_key_or_the_display_name
    by_key = Runes::Kanban.advance(SAMPLE, title: "Appeler Jean Dupont", to: "blocked")
    by_name = Runes::Kanban.advance(SAMPLE, title: "Appeler Jean Dupont", to: "Blocked")

    assert_equal by_key, by_name
    # Blocked already held "Valider le budget marketing": the moved task is
    # appended, and the fixture's own task is untouched.
    assert_equal ["Valider le budget marketing", "Appeler Jean Dupont"],
                 Runes::Kanban.tasks(by_key, column: "blocked").map(&:title)
  end

  def test_moving_an_unknown_task_raises_rather_than_silently_doing_nothing
    error = assert_raises(Runes::Kanban::Error) do
      Runes::Kanban.advance(SAMPLE, title: "No such task", to: "done")
    end
    assert_includes error.message, "No such task"
  end

  def test_an_unknown_column_is_refused
    assert_raises(Runes::Kanban::Error) { Runes::Kanban.advance(SAMPLE, title: "Appeler Jean Dupont", to: "later") }
  end

  def test_a_task_can_be_added_with_an_assignee
    updated = Runes::Kanban.add(SAMPLE, title: "Relancer les non-répondants",
                                       column: "todo", assignee: "Marie Martin")
    parsed = Runes::Kanban.parse(updated)

    task = parsed[:columns]["todo"].find { |t| t.title == "Relancer les non-répondants" }
    assert_equal "Marie Martin", task.assignee
    assert_empty Runes::Kanban.validate(updated)
  end

  def test_status_follows_the_tasks
    rendered = Runes::Kanban.render(mission: "Vide", columns: {})
    assert_equal "Todo", Runes::Kanban.parse(rendered)[:header]["status"]

    done = Runes::Kanban.render(mission: "Fini", columns: { "done" => ["a"] })
    assert_equal "Done", Runes::Kanban.parse(done)[:header]["status"]
  end

  def test_rendering_accepts_strings_hashes_and_tasks
    rendered = Runes::Kanban.render(
      mission: "Mix", code: "M-009", epic: "E-001", created_at: "2026-09-11",
      columns: { "todo" => ["plain"], "in_progress" => [{ "title" => "hashed", "assignee" => "Ada" }],
                 "done" => [Runes::Kanban::Task.new(title: "explicit", done: true)] }
    )

    assert_empty Runes::Kanban.validate(rendered)
    parsed = Runes::Kanban.parse(rendered)
    assert_equal "plain", parsed[:columns]["todo"].first.title
    assert_equal "Ada", parsed[:columns]["in_progress"].first.assignee
    assert parsed[:columns]["done"].first.done
    assert_includes rendered, "%% Code: M-009"
  end

  # --- codes, the app's way of letting one entity reference another ---------

  def test_next_code_counts_what_is_already_there
    assert_equal "E-001", Runes::Kanban.next_code([], prefix: "E")
    assert_equal "E-004", Runes::Kanban.next_code(["%% Code: E-003", "#E-001 mentioned in prose"], prefix: "E")
    assert_equal "M-002", Runes::Kanban.next_code(["%% Code: M-001"], prefix: "M")
    assert_equal "#M-002", Runes::Kanban.reference("M-002")
  end

  def test_a_file_round_trip
    Dir.mktmpdir("runes-kanban-") do |dir|
      path = File.join(dir, "missions", "mission.mmd")
      Runes::Kanban.write(path, SAMPLE)

      Runes::Kanban.advance_file(path, title: "Valider le budget marketing",
                                       to: "done", note: "pass: approved")

      text = File.read(path)
      assert_empty Runes::Kanban.validate(text)
      # The header follows the tasks: with a todo and an in-progress task left,
      # the mission is still running even though a blocked one was cleared.
      assert_equal "In Progress", Runes::Kanban.parse(text)[:header]["status"]
    end
  end

  def test_the_status_becomes_done_when_the_last_task_is
    text = SAMPLE
    %w[Appeler\ Jean\ Dupont Envoyer\ un\ email\ à\ Marie\ Martin
       Préparer\ le\ script\ d'appel Identifier\ les\ 10\ prospects
       Valider\ le\ budget\ marketing].each do |title|
      text = Runes::Kanban.advance(text, title: title, to: "done")
    end

    assert_equal "Done", Runes::Kanban.parse(text)[:header]["status"]
    assert_equal 5, Runes::Kanban.tasks(text, column: "done").size
  end
end
