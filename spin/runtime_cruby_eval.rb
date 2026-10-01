# frozen_string_literal: true

# CRuby parity shim for the spin kernel entry: the ONE Runtime capability a
# compiled Spinel kernel lacks and the self-check needs — evaluating a
# workflow source file (Spinel compiles whole programs; it cannot eval
# source at runtime). Static bindings stay OFF here on purpose: the
# kernel's static verb table is what the self-check exercises.
module Runes
  module Runtime
    def self.eval_workflow_source(workflow, source, path)
      workflow.instance_eval(source, path, 1)
    end
  end
end
