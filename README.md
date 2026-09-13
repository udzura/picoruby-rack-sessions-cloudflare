# picoruby-rack-sessions-cloudflare

Cloudflare KV and Durable Object session stores for mruby and PicoRuby, intended for
[picoruby-cloudflare-worker-wasm](https://github.com/udzura/picoruby-cloudflare-worker-wasm).
`Rack::Session::CloudflareKV` inherits `Rack::Session::Abstract::Persisted` from
[mruby-rack](https://github.com/udzura/mruby-rack). Its initializer is
`initialize(app, options = {})`.

## Build

Add the mrbgem to your existing Worker build configuration:

```ruby
# Local checkouts for development:
conf.gem gemdir: "/path/to/mruby-rack"
conf.gem gemdir: "/path/to/picoruby-rack-sessions-cloudflare"
```

The mruby-rack version must provide `Rack::Session::Abstract::Persisted`.
The gem declares mruby-rack as a dependency, so the explicit mruby-rack line is
only needed when selecting a local checkout. Do not also declare the remote
mruby-rack gem in the same build.

The gem uses `picoruby-json` on PicoRuby and `mruby-json` on ordinary mruby,
plus `mruby-time`. The Worker runtime supplies `Cloudflare::KV`; this gem does
not redefine it or supply a Cloudflare host bridge.

## Worker usage

Declare a KV binding in `wrangler.jsonc` and regenerate the bindings registry
using your Worker project's normal build command:

```jsonc
{
  "kv_namespaces": [
    { "binding": "SESSIONS", "id": "YOUR_KV_NAMESPACE_ID" }
  ]
}
```

Wrap the Rack application before registering it:

```ruby
app = lambda do |env|
  session = env["rack.session"]
  session[:visits] = (session[:visits] || 0) + 1
  [200, { "content-type" => "text/plain" }, ["Visits: #{session[:visits]}"]]
end

app = Rack::Session::CloudflareKV.new(app, {
  binding: "SESSIONS",
  expire_after: 3600,
  secure: true
})
Rackup::Handler::CloudflareWorker.run(app)
```

With `Rack::Builder`, use `use Rack::Session::CloudflareKV, binding: "SESSIONS"`.
For a local HTTP server, explicitly pass `secure: false`; the default commits
sessions only over HTTPS/WSS.

`env["rack.session"]` is a Hash subclass with string keys. Common accesses such
as `session[:user_id]` and `session["user_id"]` address the same entry. Values
must be JSON-compatible: strings, finite numbers, booleans, nil, arrays and
hashes with string keys. Nested hashes are ordinary hashes. Arbitrary Ruby
objects, symbol values, cycles and nesting deeper than 64 levels are rejected.

## Options and lifecycle

| Option | Default | Meaning |
| --- | --- | --- |
| `binding` | `"SESSIONS"` | KV namespace binding resolved from the current request |
| `prefix` | `"rack:session:"` | KV key prefix; ASCII, up to 448 bytes |
| `key` | `"rack.session"` | Cookie name |
| `expire_after` | `86400` | KV TTL and Cookie Max-Age; integer from 60 through 9007199254740991 |
| `path` | `"/"` | Cookie path |
| `domain` | `nil` | Optional cookie domain |
| `secure` | `true` | Secure cookie; commits only over HTTPS/WSS |
| `httponly` | `true` | HttpOnly cookie |
| `same_site` | `:lax` | `:lax`, `:strict`, `:none`, or nil; `:none` requires secure |

Each request gets its own options hash at `env["rack.session.options"]`:

```ruby
env["rack.session.options"][:renew] = true # Rotate ID, retain data
env["rack.session.options"][:drop] = true  # Invalidate ID and expire cookie
env["rack.session.options"][:skip] = true  # No write or cookie change
env["rack.session.options"][:defer] = true # Save without a cookie; renew overrides this
```

Choose the relevant operation; these are independent examples. Use `renew`
after a change in authentication state. `session.clear` saves an empty session
under the existing ID; use `drop` to invalidate the ID. `defer` is normally useful
only when the client already has the session cookie.

Data is loaded eagerly when a valid session cookie is present. An unused empty
session performs no KV I/O. Changes, including nested mutations, are saved after
a successful application call. Unchanged sessions do not write or refresh the
cookie/expiration; `renew` forces a write. Expiration is measured from the last
write, not the last read. Existing response cookies are retained.

Session IDs are 32 random bytes encoded as 64 lowercase hex characters, using
the runtime-provided `SecureRandom.random_bytes(32)`.
The runtime must supply `SecureRandom`; this gem contains no random-source
implementation or fallback. Missing, invalid, expired, tombstoned or malformed records are treated as new sessions and never
adopt the client-supplied ID. KV and random-source failures propagate as errors.
Session data stays in KV; only the opaque ID is sent in the cookie.

## KV limitations

The supplied KV binding supports `get` and `put(key, value, ttl:)`, but no delete.
Drop and renewal therefore overwrite the old key with JSON `null`, with a
60-second TTL. Records also contain an absolute expiration checked on reads.

Workers KV is eventually consistent: another location may temporarily read old
data, including a session that was dropped or renewed. Concurrent requests can
lose updates; an in-flight writer can also overwrite an invalidation. This store
cannot guarantee immediate global logout/revocation or atomic counters. Do not
rely on the session alone for operations requiring those guarantees.
Cloudflare also limits writes to the same key to one per second. Avoiding
unchanged writes reduces traffic but does not prevent that limit when a session
changes on every request. No automatic retry is performed.

See Cloudflare's [consistency documentation](https://developers.cloudflare.com/kv/concepts/how-kv-works/)
and [write/expiration documentation](https://developers.cloudflare.com/kv/api/write-key-value-pairs/).

## Tests

With the standard ghq sibling checkout layout:

```sh
rake test                 # Native PicoRuby + fake KV
VM=mruby rake test        # Native mruby + fake KV
rake test:worker          # Wasm + local workerd + local KV
```

Override `PICORUBY_ROOT`, `MRUBY_ROOT`, `MRUBY_RACK_ROOT`, or `WORKER_ROOT` for
other layouts. `test:worker` requires Emscripten 5 or later, Node.js, and installed
npm dependencies in `picoruby-cloudflare-worker-wasm/spike`. Build artifacts are
placed under this repository's ignored `build/` directory; PicoRuby also
regenerates its own version source during configuration.

Native tests use a deterministic `SecureRandom` test double; the workerd test
uses the actual runtime-provided implementation. The native tests cover session round trips, nested changes, invalid/expired
records, cookie attributes, TTL validation, renew/drop/skip/defer, error handling
and secure IDs. The Worker test exercises real HTTP cookies through the supplied
Wasm adapter and local KV across separate requests. It does not deploy to a
Cloudflare account or verify cross-location consistency.

## Durable Object sessions

`Rack::Session::DurableObject` uses the current
`picoruby-cloudflare-worker-wasm` Durable Object binding. Both stores inherit
`CloudflareCommon`, which provides the shared session
lifecycle and inherits `Abstract::Persisted`.

```ruby
app = Rack::Session::DurableObject.new(app, {
  binding: "SESSION",
  expire_after: 3600,
  secure: true
})
Rackup::Handler::CloudflareWorker.run(app)
```

Export the runtime's `PicoRubyDurableObject` class from your Worker entry point,
and configure the binding and migration (use the next migration tag if the
project already has migrations):

```javascript
export { PicoRubyDurableObject } from './durable-object.js';
```

```jsonc
{
  "durable_objects": {
    "bindings": [{ "name": "SESSION", "class_name": "PicoRubyDurableObject" }]
  },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["PicoRubyDurableObject"] }]
}
```

Use the `durable-object.js` supplied in the runtime's `spike/src/` directory,
and regenerate the binding registry through the project's normal build command.

The default binding is `SESSION` (singular); the other defaults match KV.
`expire_after` accepts positive safe integers starting at **1 second**.
The binding receives only `get(name)` and `put(name, POJO)` calls, without a
TTL keyword. Each session name is the configured prefix plus its random ID.
Stored POJOs contain `version`, `expires_at`, and `data`.

Session Hash conversion is available as:

```ruby
pojo = env["rack.session"].to_pojo
session = Rack::Session::Abstract::SessionHash.from_pojo(pojo)
# Optional ID and request options:
session = Rack::Session::Abstract::SessionHash.from_pojo(pojo, sid, options)
```

`to_pojo` converts user data into `Cloudflare::DurableObject::POJO`, including
hashes inside arrays. `from_pojo` restores a string-keyed session Hash with
ordinary nested hashes. Both copy nested containers and strings; session ID
and request options are not included in the user-data POJO. JSON value and
nesting restrictions are the same as for KV.

Conversion is explicit during persistence: the current runtime accepts Hash
subclasses directly and only invokes `to_pojo` for other object types. This
also works with a binding that automatically invokes `to_pojo`.

The supplied Durable Object has no TTL or delete method. Expiration is checked
on reads, and renew/drop writes an expired POJO as a tombstone. Expired records
and tombstones remain stored until a separate cleanup mechanism removes them.
This store does not add alarms or physical garbage collection.

A session update still consists of separate get/put calls around the application.
It is not a transaction: concurrent requests can overwrite each other's changes
or overwrite a tombstone. The adapter does not promise atomic session updates
or race-free invalidation merely because its backend is a Durable Object.

`rake test` and `VM=mruby rake test` run the Durable Object and POJO tests in
addition to the existing KV tests. `rake test:worker` uses the current runtime's
actual Durable Object class and local workerd to test both backends.
