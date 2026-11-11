# frozen_string_literal: true

require 'digest'
require 'json'
require 'optparse'

# Build the out-of-sample calibration set for the perception-sufficiency
# gate (PRD §7.8: the calibration set must be separate from the 24-case
# pilot, or the ECE is in-sample and meaningless).
#
#   ruby bench/swarm/build_calibration_set.rb \
#     --d1-model LiquidAI/d1-2B-MLX-8bit --python tmp/venv-swarm/bin/python \
#     --out bench/swarm/calibration-set.json
#
# The set is synthetic and disjoint from cases.json: 16 (task, perception,
# gold-sufficient) items — 8 where the perception clearly answers the task,
# 8 where it does not. Each is scored by the real d1 checkpoint with the
# same question the conductor's perception judge asks. The script records
# the (confidence, correct) pairs, computes ECE/Brier, and picks the
# sufficiency threshold that minimizes misclassification on the set.
# The runner then passes this file via --calibration and the conductor
# reads `sufficiency_threshold` from it.
module Runes
  module Bench
    module Swarm
      class CalibrationSetBuilder
        class Error < StandardError; end

        # Synthetic items, disjoint from the 24 pilot cases: (task, perception, gold)
        ITEMS = [
          ['What is the invoice total?', 'Invoice total line reads 128,40 EUR (image:1).', true],
          ['Which quarter had the highest revenue?', 'Bar chart: Q1 12, Q2 18, Q3 25, Q4 21 (image:1).', true],
          ['What does the primary button say?', 'Settings screen; primary button reads "Enregistrer" (image:1).', true],
          ['How many red circles are there?', 'Three red circles in a row, two blue squares below (image:1).', true],
          ['What is the order number?', 'Speech: "The order number is four two seven one." (time:0)', true],
          ['When is the meeting moved to?', 'Speech: "La réunion est déplacée à quatorze heures trente." (time:0)', true],
          ['What sound is playing?', 'Three short high beeps, no speech (time:0)', true],
          ['What is the spoken request?', 'Speech: "ouvrir une facture" (time:0)', true],
          ['Where is the red square?', 'Speech: "The red square is on the left."; frame shows red square left, blue circle right (time:0, image:1)', true],
          ['Is the circle blue?', 'Speech: "The circle is blue."; frame shows a red circle and a blue rectangle (time:0, image:1)', true],
          ['What is the invoice total?', 'The image shows a bar chart of quarterly revenue (image:1).', false],
          ['Which quarter had the highest revenue?', 'The document has a title and a footer (image:1).', false],
          ['What does the primary button say?', 'The screen has a sidebar with five entries (image:1).', false],
          ['How many red circles are there?', 'The image contains geometric shapes (image:1).', false],
          ['What is the order number?', 'Some speech is present but not transcribed (time:0).', false],
          ['When is the meeting moved to?', 'Audio contains ambient noise only (time:0).', false],
          ['What sound is playing?', 'The clip is silent (time:0).', false],
          ['What is the spoken request?', 'Speech is in an unidentified language (time:0).', false],
          ['Where is the red square?', 'Speech mentions a square but no position; frame not described (time:0).', false],
          ['Is the circle blue?', 'Speech and frame are unrelated to the question (time:0, image:1).', false]
        ].freeze

        def self.run(argv)
          options = { d1_model: 'LiquidAI/d1-2B-MLX-8bit', python: 'python3',
                      out: File.expand_path('calibration-set.json', __dir__), timeout_s: 300 }
          OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/swarm/build_calibration_set.rb [--d1-model M] [--python P] [--out PATH]'
            opts.on('--d1-model M') { |v| options[:d1_model] = v }
            opts.on('--python P') { |v| options[:python] = v }
            opts.on('--out PATH') { |v| options[:out] = v }
            opts.on('--timeout S', Float) { |v| options[:timeout_s] = v }
            opts.on('-h', '--help') { puts opts; exit 0 }
          end.parse!(argv)

          new(**options).build
        end

        def initialize(d1_model:, python:, out:, timeout_s: 300)
          @d1_model = d1_model
          @python = python
          @out = out
          @timeout_s = timeout_s
        end

        def build
          require_relative '../../lib/runes'
          require_relative 'metrics'
          adapter = Runes::LLM::D1Adapter.new(
            mode: :command, model: @d1_model, python: @python, timeout_s: @timeout_s
          )
          pairs = []
          items = ITEMS.each_with_index.map do |(task, perception, gold), index|
            state = { 'task' => task, 'perception' => "[perception]\n#{perception}",
                      'instruction' => 'Score whether the perception is sufficient for the task.' }
            questions = [{ 'id' => 'sufficiency', 'question' => 'Is the perception sufficient?',
                           'type' => 'probability' }]
            result = adapter.system_one(state, questions)
            artifact = result[:artifact] || {}
            answers = artifact['answers'] || []
            confidence = answers.find { |a| a['id'].to_s == 'sufficiency' }&.dig('value')
            confidence = confidence.to_f unless confidence.nil?
            pairs << { confidence: confidence, correct: gold }
            { 'id' => "cal-#{format('%02d', index + 1)}", 'task' => task,
              'perception' => perception, 'gold_sufficient' => gold,
              'judge_confidence' => confidence }
          end

          ece = Runes::Bench::Swarm::Metrics.ece(pairs.map { |p| [p[:confidence], p[:correct]] }.compact)
          brier = Runes::Bench::Swarm::Metrics.brier(pairs.map { |p| [p[:confidence], p[:correct]] }.compact)
          threshold = best_threshold(pairs)
          doc = {
            'format' => 'swarm-calibration-set-v1',
            'built_at' => Time.now.utc.strftime('%Y-%m-%d'),
            'note' => 'Out-of-sample calibration set for the perception-sufficiency gate; disjoint from cases.json. ' \
                      'The runner passes this file via --calibration; the conductor reads sufficiency_threshold.',
            'model' => @d1_model,
            'items' => items,
            'pairs' => pairs.map { |p| { 'confidence' => p[:confidence], 'correct' => p[:correct] } },
            'ece' => ece,
            'brier' => brier,
            'sufficiency_threshold' => threshold,
            'items_sha256' => Digest::SHA256.hexdigest(JSON.generate(items))
          }
          File.write(@out, JSON.pretty_generate(doc) + "\n")
          puts "wrote #{@out}"
          puts "items=#{items.size} ece=#{ece&.round(4)} brier=#{brier&.round(4)} sufficiency_threshold=#{threshold}"
          doc
        end

        private

        # The threshold minimizing misclassification on the set (ties -> the
        # lower value, i.e. decline only when clearly insufficient).
        def best_threshold(pairs)
          scored = pairs.filter_map { |p| p[:confidence] }.sort
          candidates = (scored + [0.0, 1.0]).uniq
          best = 0.30
          best_err = Float::INFINITY
          candidates.each do |t|
            err = pairs.count do |p|
              next false if p[:confidence].nil?

              predicted_sufficient = p[:confidence] >= t
              predicted_sufficient != p[:correct]
            end
            if err < best_err
              best_err = err
              best = t
            end
          end
          best.round(2)
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit(Runes::Bench::Swarm::CalibrationSetBuilder.run(ARGV) ? 0 : 2)
end
