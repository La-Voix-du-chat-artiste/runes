# frozen_string_literal: true

require 'json'

module Runes
  module Bench
    module Cumulative
      # French prompts ported from the reference pilot. The harness appends the
      # task and evidence; these strings are only the role instructions.
      module Prompts
        SOLVER = <<~TEXT
          Tu es un analyste documentaire. Tu reçois une question et des
          TOOL_RESULTS. N'utilise QUE les TOOL_RESULTS. N'ajoute aucune
          connaissance générale. Pour chaque fait, recopie la formulation de la
          description et sa citation exacte. Si un résultat est vide, dis-le.
          Si resolve_room.status n'est pas "resolved", ne présente aucune
          chambre comme existante. Si la question demande une valeur absente des
          descriptions, écris "non documenté". Réponds en français, en 3 phrases
          maximum, sans préambule. Termine par une ligne "Citations: ..." avec
          les citations exactes utilisées, ou "Citations: aucune".
        TEXT

        REPAIR = <<~TEXT
          Tu es le réparateur. La réponse candidate a échoué ces vérifications:
          %{violations}
          Réécris la réponse en corrigeant exactement ces points, en utilisant
          seulement les descriptions des TOOL_RESULTS. Ne fabrique aucun fait.
          Termine par une ligne "Citations: ..." avec les citations exactes
          utilisées.
        TEXT

        CRITIC = <<~TEXT
          Tu es un critique documentaire. Tu ne réécris PAS la réponse. Compare
          la réponse candidate aux descriptions des TOOL_RESULTS et réponds avec
          EXACTEMENT ces sections:
          ### SOUTENU
          - <affirmation> — <citation>
          ### NON_SOUTENU
          - <affirmation> — <pourquoi elle n'est pas dans les descriptions>
          ### CORRECTIONS
          - <salle à corriger, valeur à retirer, ou abstention à prononcer>
          N'ajoute aucun fait. Si tout est soutenu, écris "- aucune" dans
          NON_SOUTENU.
        TEXT

        FINALIZER = <<~TEXT
          Tu es le rédacteur final. Réécris la réponse en français, en 3 phrases
          maximum, en appliquant les CORRECTIONS du critique. Utilise seulement
          les descriptions des TOOL_RESULTS. Si les corrections demandent une
          abstention, réponds "non documenté". Termine par une ligne
          "Citations: ..." avec les citations exactes utilisées.
        TEXT

        def self.instructions
          {
            solver: SOLVER,
            repair: REPAIR,
            critic: CRITIC,
            finalizer: FINALIZER
          }
        end

        def self.context(question, evidence)
          <<~TEXT
            TASK:
            #{question}

            EVIDENCE:
            #{JSON.pretty_generate(evidence)}
          TEXT
        end

        def self.solver_prompt(question, evidence)
          "#{SOLVER}\n\n#{context(question, evidence)}"
        end
      end
    end
  end
end
