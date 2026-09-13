MRuby::CrossBuild.new("picoruby-worker-wasm") do |conf|
  conf.toolchain :clang

  conf.cc.command = "emcc"
  conf.linker.command = "emcc"
  conf.archiver.command = "emar"

  # JSPI cannot suspend through the JavaScript wrappers used by Emscripten's
  # default setjmp/longjmp implementation. Keep mruby's exception frames in
  # Wasm so an asynchronous host call can suspend directly through the VM.
  conf.cc.flags << "-sSUPPORT_LONGJMP=wasm"
  conf.cc.flags << "-sWASM_LEGACY_EXCEPTIONS=0"
  # The root build also links the mruby command-line helper.  It consumes the
  # same object files, so its final link needs the matching longjmp mode.
  conf.linker.flags << "-sSUPPORT_LONGJMP=wasm"
  conf.linker.flags << "-sWASM_LEGACY_EXCEPTIONS=0"

  conf.cc.defines << "PICORB_PLATFORM_WASM"
  conf.cc.defines << "PICORB_PLATFORM_CLOUDFLARE_WORKERS"
  conf.cc.defines << "MRB_32BIT"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # Select the single-threaded HAL carried by picoruby-worker-wasm.
  conf.ports :worker_wasm

  conf.picoruby(alloc_estalloc: false)

  mruby_gems = File.join(MRUBY_ROOT, "mrbgems", "picoruby-mruby", "lib", "mruby", "mrbgems")
  %w[
    mruby-array-ext
    mruby-pack
    mruby-catch
    mruby-class-ext
    mruby-enum-ext
    mruby-hash-ext
    mruby-kernel-ext
    mruby-metaprog
    mruby-method
    mruby-numeric-ext
    mruby-object-ext
    mruby-proc-ext
    mruby-sprintf
    mruby-string-ext
    mruby-struct
    mruby-bin-mruby
  ].each do |name|
    conf.gem gemdir: File.join(mruby_gems, name)
  end

  conf.gem gemdir: File.join(mruby_gems, "mruby-regexp")
  conf.gem gemdir: ENV.fetch("MRUBY_RACK_ROOT")
  conf.gem gemdir: ENV.fetch("SESSION_STORE_ROOT")
  conf.gem gemdir: ENV.fetch("WORKER_ROOT")
end
