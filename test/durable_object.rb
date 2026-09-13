JSON.use_regexp = false if JSON.respond_to?(:use_regexp=)
module Cloudflare
  class DurableObject
    class POJO < Hash; end
    def self.from_env(env, binding)
      raise "wrong binding" unless binding == "SESSION"
      env.fetch("test.storage")
    end
  end
end

class FakeDurableObject
  attr_reader :records, :writes, :reads
  attr_accessor :fail_get, :fail_put
  def initialize
    @records, @writes, @reads = {}, [], []
  end
  def get(key)
    raise "read failed" if @fail_get
    @reads << key
    raw = @records[key]
    raw && Rack::Session::Abstract::SessionHash.convert_pojo(JSON.parse(raw), true)
  end
  def put(key, value)
    raise "write failed" if @fail_put
    raise "expected POJO" unless value.is_a?(Cloudflare::DurableObject::POJO)
    @writes << key
    @records[key] = JSON.generate(value)
    nil
  end
end
$count = 0
def check(value)
  raise "check failed" unless value
  $count += 1
end

def fails
  begin
    yield
  rescue StandardError
    $count += 1
    return
  end
  raise "expected failure"
end

def env(db, cookie = nil)
  { "test.storage" => db, "rack.url_scheme" => "https", "HTTP_COOKIE" => cookie }
end

def store(options = {}, &block)
  Rack::Session::DurableObject.new(lambda do |request|
    block.call(request)
    [200, { "set-cookie" => "other=1" }, []]
  end, options)
end

def cookie(response)
  response[1]["set-cookie"].last.split(";", 2).first
end

check(Rack::Session::DurableObject.superclass == Rack::Session::CloudflareCommon)
db = FakeDurableObject.new
session = Rack::Session::Abstract::SessionHash.new({ "nested" => [{ "name" => "Alice" }] }, "private-id", { skip: true })
pojo = session.to_pojo
check(pojo.is_a?(Cloudflare::DurableObject::POJO))
check(pojo["nested"][0].is_a?(Cloudflare::DurableObject::POJO))
check(pojo.keys == ["nested"])
restored = Rack::Session::Abstract::SessionHash.from_pojo(pojo, "id", {})
check(restored[:nested] == session[:nested] && restored.id == "id")
restored[:nested][0]["name"].replace("Bob")
check(pojo["nested"][0]["name"] == "Alice")
fails { Rack::Session::Abstract::SessionHash.from_pojo({}) }
cycle = []; cycle << cycle
fails { Rack::Session::Abstract::SessionHash.new({ "cycle" => cycle }, nil, {}).to_pojo }

empty = store { |request| check(request["rack.session"].respond_to?(:to_pojo)) }
empty.call(env(db))
check(db.reads.empty? && db.writes.empty?)
store({ expire_after: 1 }) {}
writer = store({ expire_after: 60 }) do |request|
  s = request["rack.session"]
  s[:visits] = (s[:visits] || 0) + 1
  s[:nested] = { "items" => [1] }
end
first = writer.call(env(db))
first_cookie = cookie(first)
key = db.writes.last
record = JSON.parse(db.records[key])
check(record["data"]["visits"] == 1)
check(record["expires_at"] > Time.now.to_i)
reader = store { |request| check(request["rack.session"][:visits] == 1) }
writes = db.writes.size
reader.call(env(db, first_cookie))
check(db.writes.size == writes)
writer.call(env(db, first_cookie))
check(JSON.parse(db.records[key])["data"]["visits"] == 2)
store { |r| r["rack.session"][:nested]["items"] << 2 }.call(env(db, first_cookie))
check(JSON.parse(db.records[key])["data"]["nested"]["items"] == [1, 2])
renew = store { |r| r["rack.session.options"][:renew] = true }
renewed_cookie = cookie(renew.call(env(db, first_cookie)))
check(renewed_cookie != first_cookie)
check(JSON.parse(db.records[key])["expires_at"] == 0)
check(JSON.parse(db.records[db.writes.last])["data"]["visits"] == 2)
store { |r| check(r["rack.session"].empty?) }.call(env(db, first_cookie))
drop = store { |r| r["rack.session.options"][:drop] = true }
check(drop.call(env(db, renewed_cookie))[1]["set-cookie"].last.include?("Max-Age=0"))
store { |r| check(r["rack.session"].empty?) }.call(env(db, renewed_cookie))

unknown = "rack.session=" + "a" * 64
check(cookie(writer.call(env(db, unknown))) != unknown)
[{}, { "version" => 1, "expires_at" => Time.now.to_i - 1, "data" => { "visits" => 99 } }, { "version" => 1, "expires_at" => Time.now.to_i + 100, "data" => [] }].each do |bad|
  db.records["rack:session:" + "a" * 64] = JSON.generate(bad)
  check(cookie(writer.call(env(db, unknown))) != unknown)
end
reads = db.reads.size
writer.call(env(db, "rack.session=bad"))
check(db.reads.size == reads)
writes = db.writes.size
store { |r| r["rack.session"][:x] = 1; r["rack.session.options"][:skip] = true }.call(env(db))
check(db.writes.size == writes)
[0, -1, nil, 0.5, "60", 9_007_199_254_740_992].each { |ttl| fails { store({ expire_after: ttl }) {} } }
db.fail_get = true
fails { writer.call(env(db, first_cookie)) }
db.fail_get = false
db.fail_put = true
fails { writer.call(env(db)) }
puts "Durable Object sessions: #{$count} checks PASS"
