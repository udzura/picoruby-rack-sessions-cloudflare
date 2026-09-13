# Mirror the parser setup performed by the real Worker binding.
JSON.use_regexp = false if JSON.respond_to?(:use_regexp=)

# No host runtime is required: this fake exposes exactly the current KV API.
module Cloudflare
  class KV
    def self.from_env(env, binding)
      raise "wrong binding" unless binding == "SESSIONS"
      env.fetch("test.kv")
    end
  end
end

class FakeKV
  attr_reader :data, :writes, :reads
  attr_accessor :fail_get, :fail_put
  def initialize
    @data, @writes, @reads = {}, [], []
  end
  def get(key)
    raise "KV read failed" if @fail_get
    @reads << key
    @data[key]
  end
  def put(key, value, ttl: nil)
    raise "KV write failed" if @fail_put
    @writes << [key, value, ttl]
    @data[key] = value
    nil
  end
end

$count = 0
def check(message, condition)
  raise message unless condition
  $count += 1
end

def fails(message)
  begin
    yield
  rescue StandardError
    $count += 1
    return
  end
  raise message
end

def request(kv, cookie = nil, scheme = "https")
  { "test.kv" => kv, "HTTP_COOKIE" => cookie, "rack.url_scheme" => scheme }
end

def store(options = {}, &block)
  Rack::Session::CloudflareKV.new(lambda do |env|
    block.call(env)
    [200, { "set-cookie" => "other=1" }, ["ok"]]
  end, options)
end

def cookie(response)
  value = response[1]["set-cookie"]
  value = value.last if value.is_a?(Array)
  value.split(";", 2).first
end

kv = FakeKV.new
empty = store { |env| check("session is Hash", env["rack.session"].is_a?(Hash)) }
empty.call(request(kv))
check("empty session needs no IO", kv.reads.empty? && kv.writes.empty?)
check("inherits common store", Rack::Session::CloudflareKV.superclass == Rack::Session::CloudflareCommon)
check("no custom random module", !Object.const_defined?(:CloudflareSessionRandom))
check("inherits Persisted", Rack::Session::CloudflareKV < Rack::Session::Abstract::Persisted)

writer = store do |env|
  session = env["rack.session"]
  session[:count] = (session[:count] || 0) + 1
  session[:nested] = { "items" => [1, true, nil, "日本語"] }
end
first_env = request(kv)
first = writer.call(first_env)
sid_cookie = cookie(first)
sid = sid_cookie.split("=", 2).last
check("256 bit hex ID", sid.size == 64 && sid =~ /\A[0-9a-f]+\z/)
check("session metadata", first_env["rack.session"].id == sid && first_env["rack.session.options"][:id] == sid)
check("preserves other cookie", first[1]["set-cookie"].first == "other=1")
header = first[1]["set-cookie"].last
check("secure cookie defaults", header.include?("Secure") && header.include?("HttpOnly") && header.include?("SameSite=Lax") && header.include?("Max-Age=86400"))
check("default TTL", kv.writes.last[2] == 86400)
check("cookie contains no session data", !header.include?("nested"))
reader = store do |env|
  s = env["rack.session"]
  check("symbol and string reads", s[:count] == 1 && s["count"] == 1)
  check("fetch and key?", s.fetch(:count) == 1 && s.key?(:count))
  check("nested JSON round trip", s[:nested]["items"] == [1, true, nil, "日本語"])
end
writes = kv.writes.size
reader.call(request(kv, sid_cookie))
check("read only does not write", writes == kv.writes.size)
writer.call(request(kv, sid_cookie))
check("updates same ID", kv.writes.last[0] == "rack:session:" + sid)
check("persistent counter", JSON.parse(kv.writes.last[1])["data"]["count"] == 2)

nested = store { |env| env["rack.session"][:nested]["items"] << "changed" }
nested.call(request(kv, sid_cookie))
check("nested mutation saved", JSON.parse(kv.writes.last[1])["data"]["nested"]["items"].last == "changed")

unknown = "a" * 64
replacement = writer.call(request(kv, "rack.session=" + unknown))
check("does not adopt unknown cookie", cookie(replacement) != "rack.session=" + unknown)
reads = kv.reads.size
writer.call(request(kv, "rack.session=../../bad"))
check("invalid cookie never read from KV", kv.reads.size == reads)

["null", "[]", "{", '{"version":1}', JSON.generate({ "version" => 1, "expires_at" => Time.now.to_i - 1, "data" => { "count" => 99 } })].each do |raw|
  kv.data["rack:session:" + unknown] = raw
  response = writer.call(request(kv, "rack.session=" + unknown))
  check("invalid or expired record rotates ID", cookie(response) != "rack.session=" + unknown)
end

renew = store { |env| env["rack.session.options"][:renew] = true }
rotated = renew.call(request(kv, sid_cookie))
check("renew rotates ID", cookie(rotated) != sid_cookie)
check("renew invalidates old ID", kv.data["rack:session:" + sid] == "null")
check("renew retains data", JSON.parse(kv.writes.last[1])["data"]["count"] == 2)
check("tombstone TTL", kv.writes[-2][2] == 60)

drop = store { |env| env["rack.session.options"][:drop] = true }
dropped = drop.call(request(kv, cookie(rotated)))
check("drop expires cookie", dropped[1]["set-cookie"].last.include?("Max-Age=0"))
check("drop writes tombstone", kv.writes.last[1] == "null")

writes = kv.writes.size
skip = store { |env| env["rack.session"][:ignored] = true; env["rack.session.options"][:skip] = true }
skipped = skip.call(request(kv))
check("skip no cookie or write", kv.writes.size == writes && skipped[1]["set-cookie"] == "other=1")
writer.call(request(kv, nil, "http"))
check("secure session not committed over HTTP", kv.writes.size == writes)
local = store({ secure: false, expire_after: 60 }) { |env| env["rack.session"][:local] = true }
local.call(request(kv, nil, "http"))
check("explicit HTTP with custom TTL", kv.writes.last[2] == 60)

defer = store({ defer: true }) { |env| env["rack.session"][:deferred] = true }
deferred = defer.call(request(kv))
check("defer writes without cookie", kv.writes.last[1].include?("deferred") && deferred[1]["set-cookie"] == "other=1")

[0, 59, nil, 1.5, "60", 9_007_199_254_740_992].each do |ttl|
  fails("invalid TTL accepted") { store({ expire_after: ttl }) {} }
end
fails("cookie injection accepted") { store({ path: "/; injected=1" }) {} }
fails("bad cookie name accepted") { store({ key: "bad\r\n" }) {} }
fails("insecure SameSite None accepted") { store({ secure: false, same_site: :none }) {} }
fails("oversized prefix accepted") { store({ prefix: "x" * 449 }) {} }

kv.fail_get = true
fails("read failure swallowed") { reader.call(request(kv, sid_cookie)) }
kv.fail_get = false
kv.fail_put = true
fails("write failure swallowed") { writer.call(request(kv)) }
kv.fail_put = false

ids = []
20.times { ids << cookie(writer.call(request(kv))) }
check("session IDs unique", ids.uniq.size == 20)
bad_values = [Object.new, { :symbol => 1 }, [Float::INFINITY]]
bad_values.each do |value|
  fails("non-JSON value accepted") do
    store { |env| env["rack.session"][:bad] = value }.call(request(kv))
  end
end
cyclic = []
cyclic << cyclic
fails("cyclic data accepted") { store { |env| env["rack.session"][:cycle] = cyclic }.call(request(kv)) }
store { |env| env["rack.session"][:float] = 1.5 }.call(request(kv))
check("finite float saved", JSON.parse(kv.writes.last[1])["data"]["float"] == 1.5)

class ClosingBody
  attr_reader :closed
  def close; @closed = true end
end
body = ClosingBody.new
broken = Rack::Session::CloudflareKV.new(lambda do |env|
  env["rack.session"][:value] = true
  [200, {}, body]
end)
kv.fail_put = true
fails("commit failure swallowed") { broken.call(request(kv)) }
check("body closed after commit failure", body.closed)
kv.fail_put = false

writes = kv.writes.size
fails("app error swallowed") do
  store { |env| env["rack.session"][:oops] = true; raise "app failure" }.call(request(kv))
end
check("app failure does not persist", kv.writes.size == writes)

clear = store { |env| env["rack.session"].clear }
current = writer.call(request(kv))
clear.call(request(kv, cookie(current)))
check("clear persists empty data", JSON.parse(kv.writes.last[1])["data"] == {})

isolated = store do |env|
  env["rack.session"][:value] = 1
  env["rack.session.options"][:skip] = true if env["test.skip"]
end
skip_env = request(kv)
skip_env["test.skip"] = true
isolated.call(skip_env)
response = isolated.call(request(kv))
check("request options do not leak", response[1]["set-cookie"].is_a?(Array))

puts "session store: #{$count} checks PASS"
