require "test_helper"

# O1.6 — the plugin catalog renders the seven runes straight from the
# registry, so the page cannot go stale.
class PluginsControllerTest < ActionDispatch::IntegrationTest
  def test_index_renders_the_seven_runes_with_descriptions
    get plugins_path
    assert_response :success
    %w[cmd ruby chat agent map repeat call].each do |rune|
      assert_select "td.mono", text: rune
    end
    assert_select "td", text: /Run a command and capture its output/
    assert_select "td", text: /Prompt a cloud LLM/
    assert_select "th", text: "Source"
  end
end
