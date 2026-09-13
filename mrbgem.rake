MRuby::Gem::Specification.new("picoruby-rack-sessions-cloudflare") do |spec|
  spec.license = "MIT"
  spec.author = "Kondo Uchio"
  spec.summary = "Cloudflare KV and Durable Object session stores for mruby-rack"
  spec.version = "0.1.0"
  spec.rbfiles = %w[cloudflare_common cloudflare_kv durable_object].map { |name| File.join(dir, "mrblib", "#{name}.rb") }

  spec.add_dependency "mruby-rack", github: "udzura/mruby-rack", branch: "master"
  pico_gems = File.join(MRUBY_ROOT, "mrbgems", "picoruby-mruby", "lib", "mruby", "mrbgems")
  if File.directory?(pico_gems)
    spec.add_dependency "picoruby-json"
    spec.add_dependency "mruby-time", gemdir: File.join(pico_gems, "mruby-time")
  else
    spec.add_dependency "mruby-json", github: "mattn/mruby-json"
    spec.add_dependency "mruby-time"
  end
end
