require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

# Tests must never touch the developer's project tree or the network
# (B4-1 / B4-13 / E4-2):
#   * RUNES_ROOT points Settings at a throwaway tree, so the preferences
#     DB, journal, docs and policy of the real checkout are untouched and
#     config/.env is never read.
#   * Provider keys are stripped from the process ENV so no test can make
#     a live API call by accident. Provider behaviour is exercised through
#     the injectable transport (LLMClient.new(settings, transport: ...)),
#     i.e. a fake/dup of the real HTTP call — never the network.
TEST_ROOT = Dir.mktmpdir('runes-test-root')
ENV['RUNES_ROOT'] = TEST_ROOT
# D5-2: strip EVERY provider key the harness knows about (not just the
# three seeded providers) and the adapter selector, so no test can make a
# live API call or pick a community adapter by accident.
%w[
  DEEPSEEK DEEPSEEK_API_KEY SYNTHETIC SYNTHETIC_API_KEY CEREBRAS CEREBRAS_API_KEY
  OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY PERPLEXITY_API_KEY
  RUNES_LLM_ADAPTER
].each do |key|
  ENV.delete(key)
end
Minitest.after_run { FileUtils.remove_entry(TEST_ROOT) if Dir.exist?(TEST_ROOT) }

require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/wasm/vm_manager'
require_relative '../lib/runes/capabilities/guard'
require_relative '../lib/runes/core/dispatcher'

# A publisher double. The pipeline takes its transport as a positional
# argument, so a test can assert on what an agent would have published
# without starting a broker or a transport thread.
class RecordingTransport
  attr_reader :published

  def initialize
    @published = []
    @subscriptions = []
  end

  def publish(topic, payload, **options)
    @published << { topic: topic, payload: payload }.merge(options)
    @published.size
  end

  def subscribe(filter, **_options)
    @subscriptions << filter
    :stub
  end
  def unsubscribe(*) = true
  def connect = self
  def disconnect = self
  def connected? = true
  def alive? = true
  def supports_groups? = true
  def supports_properties? = true
  def describe = "RecordingTransport"

  attr_reader :subscriptions

  def topics = @published.map { |p| p[:topic] }
  def payloads = @published.map { |p| p[:payload] }
  def to = ->(topic) { @published.select { |p| p[:topic] == topic } }
end
