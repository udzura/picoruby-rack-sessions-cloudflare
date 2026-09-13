app = lambda do |env|
  session = env["rack.session"]
  case env["PATH_INFO"]
  when "/renew"
    env["rack.session.options"][:renew] = true
  when "/drop"
    env["rack.session.options"][:drop] = true
  when "/read"
  else
    session[:count] = (session[:count] || 0) + 1
  end
  [200, { "content-type" => "application/json", "set-cookie" => "other=1" }, [JSON.generate(session)]]
end
kv = Rack::Session::CloudflareKV.new(app, expire_after: 60)
durable = Rack::Session::DurableObject.new(app, expire_after: 60)
PicoRubyWorker::RackAdapter.register(lambda do |env|
  if env["PATH_INFO"].start_with?("/do/")
    env["PATH_INFO"] = env["PATH_INFO"][3..-1]
    durable.call(env)
  else
    kv.call(env)
  end
end)
