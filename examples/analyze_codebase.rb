# frozen_string_literal: true

# The example from the Shopify Roast README, unmodified:
# https://github.com/shopify/roast#quick-example
#
#   bin/runes-workflow execute examples/analyze_codebase.rb
#
# The same file runs under Roast's `bin/roast execute`; the only difference is
# that the verbs are Runes registered as `:rune` plugins.

execute do
  # Get recent changes
  cmd(:recent_changes) { "git diff --name-only HEAD~5..HEAD" }

  # AI agent analyzes the code
  agent(:review) do
    files = cmd!(:recent_changes).lines
    <<~PROMPT
      Review these recently changed files for potential issues:
      #{files.join("\n")}

      Focus on security, performance, and maintainability.
    PROMPT
  end

  # Summarize for stakeholders
  chat(:summary) do
    "Summarize this for non-technical stakeholders:\n\n#{agent!(:review).response}"
  end
end
