#!/usr/bin/env ruby
# frozen_string_literal: true

# Build the Runes kernel with Spinel (https://github.com/matz/spinel) when a
# `spinel` binary is on PATH; otherwise run the CRuby parity self-check with
# the pure backends wired in (spin/kernel.rb does that wiring). Exit 0 on
# success either way — the kernel is always verifiable, compiled or not.
#
#   ruby scripts/spinel_build.rb          # auto-detect
#   SPINEL=/path/to/spinel ruby scripts/spinel_build.rb
#
# See docs/spinel-compatibility.md and docs/spinel/PRD.md.
require 'fileutils'
require 'rbconfig'

ROOT = File.expand_path('..', __dir__)
KERNEL = File.join(ROOT, 'spin', 'kernel.rb')
OUT_DIR = File.join(ROOT, 'build')

def which(cmd)
  ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, cmd)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

spinel = ENV['SPINEL'] || which('spinel')

if spinel
  FileUtils.mkdir_p(OUT_DIR)
  binary = File.join(OUT_DIR, 'runes-kernel')
  puts "[spinel-build] compiling #{KERNEL} with #{spinel}"
  unless system(spinel, KERNEL, '-o', binary)
    warn '[spinel-build] compile failed'
    exit 1
  end
  puts '[spinel-build] running compiled kernel self-check'
  exit(system(binary, 'selfcheck') ? 0 : 1)
else
  puts '[spinel-build] no spinel binary on PATH — CRuby parity self-check ' \
       '(Fiddle-bound libcrypto, pure backends)'
  exit(system(RbConfig.ruby, File.join(ROOT, 'spin', 'kernel_cruby.rb'), 'selfcheck') ? 0 : 1)
end
