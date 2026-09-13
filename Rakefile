require "rake"

PROJECT_ROOT = File.expand_path(__dir__)

desc "Build and test the session store (VM=mruby or VM=picoruby)"
task :test do
  vm = ENV.fetch("VM", "picoruby")
  abort "VM must be mruby or picoruby" unless %w[mruby picoruby].include?(vm)
  root = ENV["#{vm.upcase}_ROOT"] || File.expand_path("../../#{vm}/#{vm}", PROJECT_ROOT)
  abort "Set #{vm.upcase}_ROOT to a #{vm} checkout" unless File.file?(File.join(root, "Rakefile"))
  build_dir = File.join(PROJECT_ROOT, "build", vm)
  env = {
    "MRUBY_CONFIG" => File.join(PROJECT_ROOT, "test", "build_config.rb"),
    "MRUBY_BUILD_DIR" => build_dir,
    "SESSION_STORE_ROOT" => PROJECT_ROOT,
    "MRUBY_RACK_ROOT" => ENV.fetch("MRUBY_RACK_ROOT", File.expand_path("../mruby-rack", PROJECT_ROOT))
  }
  Dir.chdir(root) { sh env, "rake" }
  executable = File.join(build_dir, "session-store-test", "bin", "mruby")
  %w[smoke durable_object].each do |name|
    runner = File.join(build_dir, "#{name}_test.rb")
    support = File.read(File.join(PROJECT_ROOT, "test", "support", "secure_random.rb"))
    test = File.read(File.join(PROJECT_ROOT, "test", "#{name}.rb"))
    File.write(runner, support + "\n" + test)
    sh executable, runner
  end
end

task default: :test

desc "Build Wasm and test HTTP sessions with local workerd/KV/Durable Object (requires Emscripten and the Worker spike npm dependencies)"
task "test:worker" do
  root = ENV.fetch("PICORUBY_ROOT", File.expand_path("../../picoruby/picoruby", PROJECT_ROOT))
  worker = ENV.fetch("WORKER_ROOT", File.expand_path("../picoruby-cloudflare-worker-wasm", PROJECT_ROOT))
  build_dir = File.join(PROJECT_ROOT, "build", "worker")
  env = {
    "MRUBY_CONFIG" => File.join(PROJECT_ROOT, "test", "worker_build_config.rb"),
    "MRUBY_BUILD_DIR" => build_dir,
    "SESSION_STORE_ROOT" => PROJECT_ROOT,
    "MRUBY_RACK_ROOT" => ENV.fetch("MRUBY_RACK_ROOT", File.expand_path("../mruby-rack", PROJECT_ROOT)),
    "WORKER_ROOT" => worker
  }
  Dir.chdir(root) { sh env, "rake", "all" }
  mrbc = File.join(build_dir, "mrbc", "default", "bin", "mrbc")
  sh mrbc, "-o", File.join(build_dir, "app.bin"), File.join(PROJECT_ROOT, "test", "worker_app.rb")
  sh({ "WORKER_ROOT" => worker, "SESSION_WORKER_BUILD" => build_dir }, "node", File.join(PROJECT_ROOT, "test", "worker.mjs"))
end
