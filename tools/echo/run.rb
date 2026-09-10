#!/usr/bin/env ruby
# Example WASM-backable tool.
#
# Tool contract: the harness executes this file inside the WASM sandbox
# with a JSON args object placed at /workspace/.runes-args-<id>.json.
# Write your tool as if reading args from STDIN — the harness rewrites
# `STDIN.read` to the args file at launch:
#
#   input = JSON.parse(STDIN.read) rescue {}
#
# Only the exact `STDIN.read` call is rewritten; keep to this idiom.
require 'json'
input = JSON.parse(STDIN.read) rescue {}
puts input['message'].to_s
