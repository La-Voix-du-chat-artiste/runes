#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs `examples/prospect_pipeline.rb` the way the README screenshot shows it:
# for real (or scripted), with telemetry on, so the observatory records the
# session. This exists so the picture in the README is reproducible rather than
# a one-off that nobody can regenerate.
#
#   # live (needs a provider key in config/.env), telemetry to mosquitto:
#   RUNES_TELEMETRY=mqtt ruby -Ilib scripts/demo_pipeline_run.rb
#
#   # no key, no network, deterministic (used by anyone without credentials):
#   RUNES_DEMO_SCRIPTED=1 RUNES_TELEMETRY=mqtt ruby -Ilib scripts/demo_pipeline_run.rb
#
# Then watch it: bin/runes-ingest (in another shell) and
# `cd runes_observer && bin/rails server`, at /runs and /board.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "runes"

ROOT = ENV.fetch("PROSPECT_ROOT", File.expand_path("../tmp/prospect-demo", __dir__))
IDEA = ENV.fetch("PROSPECT_IDEA",
                 "Trouver 10 PME de 10 à 100 employés intéressées par un CRM qui " \
                 "transforme une idée en mission exécutée")
# Recorded relative on purpose: the run's telemetry carries this string, and a
# screenshot of the observatory should not contain somebody's home directory.
WORKFLOW = "examples/prospect_pipeline.rb"
WORKFLOW_PATH = File.expand_path("../#{WORKFLOW}", __dir__)

# --- a scripted provider, for readers without a key ------------------------
#
# It answers each prompt by what it asks for, with a small pause so the run
# timeline has realistic durations instead of microseconds. Everything else —
# the workflow, the files, the telemetry, the observatory — is the real thing.
if %w[1 true yes on].include?(ENV["RUNES_DEMO_SCRIPTED"].to_s.downcase)
  PAUSE = ENV.fetch("RUNES_DEMO_PAUSE_S", "0.4").to_f
  TODOS = {
    "mission" => "Former 3 partenaires intégrateurs",
    "todos" => [
      { "title" => "Lister 50 PME cibles", "assignee" => "Jean Dupont" },
      { "title" => "Préparer le kit de démo", "assignee" => "Marie Martin" },
      { "title" => "Écrire la page de lancement", "assignee" => "Samir Haddad" }
    ]
  }.freeze

  # rubocop:disable Metrics/MethodLength
  def scripted_answer(prompt)
    case prompt
    when /brainstorming half/
      "## Objectif\nFormer trois partenaires intégrateurs d'ici la fin du trimestre.\n\n" \
      "1. 50 PME qualifiées contactées.\n2. Un kit de démo prêt.\n3. Une page de lancement en ligne."
    when /Break this goal into between/
      JSON.generate(TODOS)
    when /You are the verifier/
      if prompt.include?("kit de démo")
        JSON.generate("verdict" => "fail", "reason" => "le kit n'est pas encore montrable")
      else
        JSON.generate("verdict" => "pass", "reason" => "fait, vérifié à la main")
      end
    when /Execute this todo/ then "Fait : livrable écrit dans le workspace, 3 lignes de résumé."
    when /short, specific outreach message/ then "Bonjour,\n\nUne phrase concrète, sans flatterie."
    else "Réponse scriptée."
    end
  end

  provider = Object.new
  provider.define_singleton_method(:invoke) do |input|
    prompt = Array(input.prompts).last.to_s
    sleep(PAUSE)
    Runes::Plugins::Agent::Output.new(response: scripted_answer(prompt),
                                      session: "scripted",
                                      stats: Runes::Plugins::Agent::Stats.new)
  end
  Runes::Plugins::Agent.provider_factory = ->(_config) { provider }

  chat = Object.new
  chat.define_singleton_method(:chat) do |prompt:, session:, config:|
    sleep(PAUSE)
    text = "• Deux partenaires avancent\n• Un livrable bloqué (kit de démo)\n• Relancer Marie"
    Runes::Plugins::Chat::Reply.new(response: text,
                                    messages: [{ role: "user", content: prompt },
                                               { role: "assistant", content: text }],
                                    model: "scripted", input_tokens: 5, output_tokens: 12)
  end
  Runes::Plugins::Chat.backend = chat
  warn "demo: scripted provider (no key needed), pause #{PAUSE}s per call"
end

# --- telemetry, so the session is watchable --------------------------------

if ENV["RUNES_TELEMETRY"].to_s.strip.empty?
  warn "demo: RUNES_TELEMETRY is unset — the run will not reach the observatory"
else
  sink = Runes::Telemetry.build_sink(ENV["RUNES_TELEMETRY"])
  Runes::Telemetry.sink = sink
  warn "demo: telemetry -> #{sink&.topic('<run_id>', '<kind>') || 'disabled'}"
  guard = Runes::GuardTelemetry.build_sink(ENV["RUNES_TELEMETRY"])
  Runes::GuardTelemetry.sink = guard
end

# --- run it ----------------------------------------------------------------

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Dir.chdir(File.expand_path("..", __dir__)) # so the relative WORKFLOW resolves
workflow = Runes::Workflow.from_file(WORKFLOW, Runes::WorkflowParams.new([], [], { idea: IDEA }))
output = workflow.final_output
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts "workflow: #{WORKFLOW}"
puts "root:     #{ROOT}"
puts "epic:     #{output[:epic_code]}  mission: #{File.basename(output[:mission_path].to_s)}"
puts "todos:    #{output[:todos]} (#{Array(output[:advanced]).map { |t| t[:verdict] }.join(', ')})"
puts "drafts:   #{Array(output[:drafts]).size}  references: #{Array(output[:references]).join(', ')}"
puts "report:   #{output[:report_path]}"
puts format("elapsed:  %.1fs", elapsed)

# Close the telemetry sinks before exiting: the last events (including
# run_finished) are only flushed when the transport is disconnected.
Runes::Telemetry.close!
Runes::GuardTelemetry.close! if defined?(Runes::GuardTelemetry)
