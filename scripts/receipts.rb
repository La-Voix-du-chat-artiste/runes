#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the receipts `docs/WHY_RUNES.md` cites, so the pitch can be updated by
# pasting output instead of remembering numbers. The doc brags that its docs
# cannot drift; that only holds if re-measuring is one command.
#
#   ruby scripts/receipts.rb              # code sizes (fast, no suite run)
#   ruby scripts/receipts.rb --suites     # also run both suites and report them
#
# Every count names its scope, because "lines of code" without a definition is
# how a receipt turns into a claim.

require "open3"

ROOT = File.expand_path("..", __dir__)

def lines(files)
  files.sum { |path| File.file?(path) ? File.readlines(path).size : 0 }
end

def glob(pattern)
  Dir.glob(File.join(ROOT, pattern)).sort
end

def section(title)
  puts "\n#{title}"
  puts "-" * title.length
end

section "Harness"
lib_files = glob("lib/**/*.rb")
test_files = glob("test/**/*.rb")
puts format("%-22s %s lines across %s files", "lib/", lines(lib_files), lib_files.size)
puts format("%-22s %s lines across %s files", "test/", lines(test_files), test_files.size)
puts format("%-22s %s lines", "dispatcher", lines(glob("lib/runes/core/dispatcher.rb")))
puts format("%-22s %s lines", "MQTT 5 adapter", lines(glob("lib/runes/transport/mqtt5.rb")))
puts format("%-22s %s lines", "request ledger", lines(glob("lib/runes/request_ledger.rb")))

section "Workflow engine"
runes = %w[agent chat repeat cmd map ruby call]
runes.each do |rune|
  puts format("%-22s %s lines", "rune #{rune}", lines(glob("lib/runes/plugins/#{rune}.rb")))
end
engine_set = glob("lib/runes/workflow.rb") + glob("lib/runes/workflow/*.rb") +
             glob("lib/runes/plugins/*.rb") + glob("lib/runes/command_runner.rb") +
             glob("lib/runes/{rune,cog,plugin,cog_input_context,workflow_policy}.rb")
puts format("%-22s %s lines (engine + runes + rune/cog/plugin support)", "total", lines(engine_set))

section "Security surfaces"
security_set = {
  "command policy" => glob("lib/runes/security/command_policy.rb"),
  "credentials" => glob("lib/runes/security/credentials.rb"),
  "envelopes" => glob("lib/runes/security/envelope.rb"),
  "identities" => glob("lib/runes/security/identity.rb"),
  "trust store" => glob("lib/runes/security/trust_store.rb"),
  "capability guard" => glob("lib/runes/capabilities/guard.rb"),
  "guard telemetry" => glob("lib/runes/guard_telemetry.rb"),
  "RPC auth" => glob("lib/runes/security/rpc_auth.rb"),
  "nonce cache" => glob("lib/runes/security/nonce_cache.rb")
}
security_set.each { |name, files| puts format("%-22s %s lines", name, lines(files)) }
puts format("%-22s %s lines", "total", lines(security_set.values.flatten))

section "Observatory"
app_files = glob("runes_observer/app/**/*.rb") + glob("runes_observer/app/**/*.erb")
puts format("%-22s %s lines of app code across %s files", "", lines(app_files), app_files.size)

section "Examples"
glob("examples/*.rb").each do |path|
  puts format("%-22s %s lines", File.basename(path), lines([path]))
end

section "Executables"
puts glob("bin/*").select { |path| File.file?(path) }.map { |path| File.basename(path) }.join(", ")

if ARGV.include?("--suites")
  section "Suites (slower)"
  {
    "parent harness" => "bundle exec rake test",
    "observatory" => "bin/rails test"
  }.each do |label, command|
    dir = label == "observatory" ? File.join(ROOT, "runes_observer") : ROOT
    out, = Open3.capture2e(command, chdir: dir)
    summary = out.lines.grep(/^\d+ runs,/).last.to_s.strip
    puts format("%-22s %s", label, summary.empty? ? "no summary line found" : summary)
  end
else
  section "Suites"
  puts "not run — pass --suites (parent: `bundle exec rake test`, observatory: `cd runes_observer && bin/rails test`)"
end
