# frozen_string_literal: true

# Child-process host for the ruby.wasm transport guest.
#
# The adapter deliberately does NOT run the VM in-process: wasmtime-ruby's
# `invoke` keeps the CRuby GVL while guest code executes, so a long-lived
# guest starves the adapter's frame pump and its timers (measured: the host
# heartbeat thread never ran while a guest loop was alive, and the 5 ms
# poll interval made no difference). In a child OS process the parent's
# threads stay schedulable; the bridge is still the same preopened files.
#
#   ruby wasm/wasm_host.rb WORK_DIR WASM_PATH GUEST_PATH
#
# WASM_PATH is ruby.wasm; GUEST_PATH is the plain-Ruby guest program. The
# guest runs as `ruby -e <source>` with WORK_DIR mapped to /work, exactly
# as the in-process spawn used to.

require "wasmtime"

work_dir, wasm_path, guest_path = ARGV
unless work_dir && wasm_path && guest_path
  warn "usage: wasm_host.rb WORK_DIR WASM_PATH GUEST_PATH"
  exit 2
end

begin
  program = File.read(guest_path)
  engine = Wasmtime::Engine.new
  mod = Wasmtime::Module.from_file(engine, wasm_path)
  linker = Wasmtime::Linker.new(engine)
  Wasmtime::WASI::P1.add_to_linker_sync(linker)
  wasi = Wasmtime::WasiConfig.new
  wasi.set_argv(["ruby", "-e", program])
  wasi.set_stdin_string("")
  wasi.set_stdout_file(File.join(work_dir, "guest-stdout.log"))
  wasi.set_stderr_file(File.join(work_dir, "guest-stderr.log"))
  begin
    wasi.set_mapped_directory(work_dir, "/work", :all, :all)
  rescue TypeError, ArgumentError
    wasi.set_mapped_directory(work_dir, "/work", 0o755, 0o644)
  end
  store = Wasmtime::Store.new(engine, wasi_p1_config: wasi)
  instance = linker.instantiate(store, mod)
  instance.invoke("_start")
rescue LoadError => e
  warn "wasm_host: the wasmtime gem is required: #{e.message}"
  exit 1
rescue StandardError => e
  warn "wasm_host: #{e.class}: #{e.message}"
  exit 1
end
