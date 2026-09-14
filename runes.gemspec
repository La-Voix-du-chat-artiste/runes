# frozen_string_literal: true

# Packaging for the Runes harness.
#
# The file list is an explicit allow-list, not `git ls-files`: this
# checkout also carries live provider keys (config/.env), local runtime
# state (runes.db, log/, tmp/, workspace/) and a ~35MB ruby.wasm binary.
# None of that may ever be baked into a published gem.
require_relative 'lib/runes/version'

# Local, not a top-level constant: gemspecs are evaluated into the global
# namespace by `gem build`/Bundler and must not leak names.
gem_root = File.expand_path(__dir__)
executables = %w[runes runes-daemon runes-client runes-replay runes-mcp runes-acl runes-workflow]

Gem::Specification.new do |spec|
  spec.name        = 'runes'
  spec.version     = Runes::VERSION
  spec.authors     = ['Runes contributors']
  spec.summary     = 'Transport-agnostic agent harness with an MQTT/A2A fabric and pluggable LLM router'
  spec.description =
    'Runes runs planner-driven tool calls over a transport-agnostic messaging fabric ' \
    '(MQTT 3.1.1/5 or in-process), with A2A-over-MQTT discovery, capability-based tool ' \
    'access control, an optional WASM sandbox for untrusted tools, and a provider seam ' \
    'over its built-in OpenAI-compatible LLM router.'
  # The project's public home. `source_code_uri`/`changelog_uri` derive from it,
  # so it must match the remote you actually publish to. See GEM_PACKAGING.md.
  spec.homepage    = 'https://github.com/La-Voix-du-chat-artiste/runes'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => spec.homepage,
    'changelog_uri'         => "#{spec.homepage}/blob/master/DEVELOPMENT_LOG.md",
    'rubygems_mfa_required' => 'true'
  }

  # Runtime deps only for what `require "runes"` actually loads. `wasmtime`
  # is deliberately NOT one of them: the WASM sandbox is optional and the
  # harness falls back to its mock backend. Users opt in with
  # `gem install wasmtime` (see GEM_PACKAGING.md).
  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'mqtt', '~> 0.7'
  spec.add_dependency 'sqlite3', '>= 2.1'

  spec.bindir      = 'bin'
  # Only ship executables that exist on disk, so a renamed/removed script
  # cannot break `gem build`.
  spec.executables = executables.select { |exe| File.file?(File.join(gem_root, 'bin', exe)) }
  spec.require_paths = ['lib']

  spec.files = Dir.chdir(gem_root) do
    %w[
      lib/**/*.rb
      bin/*
      tools/**/*
      examples/**/*
      config/policy.json
      config/.env.example
      README.md
      LICENSE
    ].flat_map { |pattern| Dir.glob(pattern) }
     .select { |path| File.file?(path) }
     .uniq
     .sort
  end
end
