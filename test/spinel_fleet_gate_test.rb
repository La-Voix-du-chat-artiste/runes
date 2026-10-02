# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/runes/fleet"

# The L3 conformance gate (docs/FLEET_DSL.md §11): every example fleet
# file must COMPILE AND RUN under Spinel, whole-program, against the
# minimal declaration stub (the real loader stays CRuby-only — it needs
# Prism and instance_eval of source strings; compiled kernels bake the
# loaded world instead, the workflow pattern).
#
# Non-blocking while Spinel matures (§11, L3): a compiler REFUSAL skips
# with the compiler's message; a wrong build (compiled, but the binary
# misbehaves) still fails — a silent wrong answer is never skipped.
class SpinelFleetGateTest < Minitest::Test
  STUB = File.expand_path("fixtures/fleet/spinel_gate_stub.rb", __dir__)
  EXAMPLES = Dir[File.expand_path("../examples/*.fleet.rb", __dir__)].sort

  def test_example_fleet_files_compile_and_run_under_spinel
    spinel = find_spinel
    skip "no spinel binary on PATH (set SPINEL=/path/to/spinel to enable)" if spinel.nil?
    skip "no example fleet files" if EXAMPLES.empty?

    EXAMPLES.each do |fleet|
      name = File.basename(fleet)
      Dir.mktmpdir("fleet-gate-", tmp_root) do |dir|
        FileUtils.cp(STUB, File.join(dir, "stub.rb"))
        FileUtils.cp(fleet, File.join(dir, "target.rb"))
        File.write(File.join(dir, "main.rb"), <<~RUBY)
          require_relative "stub"
          require_relative "target"
          puts "FLEET GATE OK"
        RUBY

        binary = File.join(dir, "gate_bin")
        compile = IO.popen([spinel, File.join(dir, "main.rb"), "-o", binary],
                           err: %i[child out], &:read)
        unless $?.success? && File.exist?(binary)
          skip "#{name}: spinel refused (non-blocking per FLEET_DSL.md §11 L3):\n#{compile}"
        end

        out = IO.popen([binary], err: %i[child out], &:read)
        assert $?.success?, "#{name}: compiled but exited #{$?.exitstatus}: #{out}"
        assert_includes out, "FLEET GATE OK", "#{name}: unexpected output: #{out}"
      end
    end
  end

  private

  def find_spinel
    from_env = ENV["SPINEL"]
    return File.expand_path(from_env) if from_env && !from_env.empty? && File.exist?(from_env)

    path = `command -v spinel 2>/dev/null`.strip
    path.empty? ? nil : path
  end

  # Scratch space stays inside the project (gitignored), per house rule.
  def tmp_root
    root = File.expand_path("../tmp", __dir__)
    FileUtils.mkdir_p(root)
    root
  end
end
