MRuby::Build.new("session-store-test") do |conf|
  conf.toolchain :clang
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  pico_gems = File.join(MRUBY_ROOT, "mrbgems", "picoruby-mruby", "lib", "mruby", "mrbgems")
  if File.directory?(pico_gems)
    conf.cc.defines << "PICORB_PLATFORM_POSIX"
    conf.picoruby(alloc_estalloc: false)
    conf.gem core: "mruby-bin-mrbc"
    gems = pico_gems
  else
    gems = File.join(MRUBY_ROOT, "mrbgems")
    conf.gem core: "mruby-bin-mrbc"
  end

  %w[
    mruby-array-ext mruby-class-ext mruby-hash-ext mruby-kernel-ext
    mruby-metaprog mruby-method mruby-numeric-ext mruby-object-ext
    mruby-proc-ext mruby-regexp mruby-sprintf mruby-string-ext
    mruby-time mruby-io mruby-bin-mruby
  ].each { |name| conf.gem gemdir: File.join(gems, name) }

  conf.gem gemdir: ENV.fetch("MRUBY_RACK_ROOT")
  conf.gem gemdir: ENV.fetch("SESSION_STORE_ROOT")
end
