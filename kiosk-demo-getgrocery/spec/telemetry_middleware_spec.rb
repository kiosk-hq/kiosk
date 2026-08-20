# frozen_string_literal: true

# Standalone (no rails boot, no DB, no network) unit spec for
# `app/services/demo_telemetry_middleware.rb` — `DemoTelemetryMiddleware`. Run:
#   bundle exec rake demo:telemetry_spec   (or: ruby spec/telemetry_middleware_spec.rb)
#
# WHY THIS EXISTS (K-622). The middleware is what produces every real telemetry
# event in the hosted deploy, and until this file NOTHING anywhere in the
# monorepo executed it — `demo:telemetry` gates the STORE round-trip
# (simulate! → aggregates), not the request path. That mattered more than usual
# because the middleware is best-effort by construction: it rescues and carries
# on, so a break in it reads to a visitor as "no activity yet" rather than as a
# failure. Nothing could turn it red.
#
# It also HAD a defect that only an executable test would have caught: the outer
# `rescue StandardError` sat below `status, headers, body = @app.call(env)` and
# recovered with `@app.call(env)` — so any raise AFTER the app had already run
# DISPATCHED THE WHOLE REQUEST A SECOND TIME. On /auth/register (the one path
# that buffers the response body, and so the one with a raiser the module does
# not individually rescue) that replay minted a SECOND agent.
#
# What is pinned here:
#   • the app is called EXACTLY ONCE, whatever telemetry does — the K-622
#     regression, asserted for both a raising telemetry call and a raising
#     response body;
#   • a telemetry failure returns the app's own status/headers/body unchanged;
#   • the /auth/register buffering hands downstream the SAME BYTES, in a
#     re-enumerable form, and closes the original body;
#   • the recording rules themselves: the 0.4 path/method classifier, 2xx-only,
#     the per-app verb_map, the register/bearer agent refs, and that the
#     request body is never read at all.
# DB-free on purpose: DemoTelemetry.record is stubbed, so this needs neither
# Postgres nor the telemetry table (getgrocery ships no rspec — same plain-ruby
# shape as spec/delivery_slots_spec.rb and spec/cashier_order_ref_spec.rb).

require "json"
require "stringio"
# demo_telemetry_record.rb declares `class DemoTelemetryRecord < ActiveRecord::Base`
# at load time. Loading the constant costs ~0.2 s and opens NO connection.
require "active_record"

ENV["KIOSK_TELEMETRY"] = "1"
# Three files since K-502, one per constant, so Zeitwerk can reach each by name
# under app/services. This driver boots no Rails, so it names them itself.
require_relative "../app/services/demo_telemetry"
require_relative "../app/services/demo_telemetry_record"
require_relative "../app/services/demo_telemetry_middleware"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# ── Test doubles ─────────────────────────────────────────────────────────────

# Every DemoTelemetry.record call lands here instead of in Postgres.
RECORDED = []
$record_raises = false

DemoTelemetry.define_singleton_method(:record) do |action_kind:, agent: nil, **_rest|
  raise "telemetry store unreachable" if $record_raises

  RECORDED << { kind: action_kind, agent: agent }
  nil
end

# The response body a broken/lazy app hands back: yields some chunks, then
# raises. This is the raiser the module does NOT individually rescue, i.e. the
# one that reached K-622's re-dispatch in production shape.
class BodyBoom < StandardError; end

class ExplodingBody
  attr_reader :closed

  def initialize(chunks = ['{"agent_id":"agt_'])
    @chunks = chunks
    @closed = false
  end

  def each(&)
    @chunks.each(&)
    raise BodyBoom, "the response body blew up mid-enumeration"
  end

  def close
    @closed = true
  end
end

# A multi-chunk, closable body — the shape a streaming app returns.
class ChunkedBody
  attr_reader :closed, :enumerations

  def initialize(chunks)
    @chunks = chunks
    @closed = false
    @enumerations = 0
  end

  def each(&)
    @enumerations += 1
    @chunks.each(&)
  end

  def close
    @closed = true
  end
end

# Counts its own dispatches — the whole point of the K-622 regression — and
# reads rack.input the way a real Rails app does.
class FakeApp
  attr_reader :calls, :registrations, :read_bodies

  def initialize(status: 200, headers: nil, &body_factory)
    @status  = status
    @headers = headers || { "content-type" => "application/json" }
    @body_factory = body_factory || -> { ['{"agent_id":"agt_9f3","expires_in":3600}'] }
    @calls = 0
    @registrations = 0
    @read_bodies = []
  end

  def call(env)
    @calls += 1
    @registrations += 1 if env["PATH_INFO"].to_s.end_with?("/auth/register")
    @read_bodies << env["rack.input"]&.read
    [@status, @headers, @body_factory.call]
  end
end

VERB_MAP = {
  "create_order"        => "ordered",
  "reschedule_delivery" => "scheduled",
  "payment_setup"       => "ran",
}.freeze

def env_for(path, method: "POST", body: nil, bearer: nil)
  env = { "REQUEST_METHOD" => method, "PATH_INFO" => path }
  env["rack.input"] = StringIO.new(body) if body
  env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
  env
end

# Read a Rack body whatever shape it is (Array, or an object answering #each).
def body_bytes(body)
  out = +""
  body.each { |chunk| out << chunk.to_s }
  out
end

def run(app, path, method: "POST", body: nil, bearer: nil, verb_map: VERB_MAP)
  RECORDED.clear
  DemoTelemetryMiddleware.new(app, verb_map: verb_map)
                         .call(env_for(path, method: method, body: body, bearer: bearer))
end

# ═════════════════════════════════════════════════════════════════════════════
# K-622 — THE APP IS DISPATCHED EXACTLY ONCE, WHATEVER TELEMETRY DOES
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── K-622: telemetry never re-dispatches the request ──"

# (a1) A raising telemetry call on a non-buffered verb. Before the fix the outer
#      rescue recovered with @app.call(env): a SECOND /pay.
$record_raises = true
app = FakeApp.new
status, headers, body = run(app, "/kiosk/pay", body: "{}", bearer: "tok-abc")
assert(app.calls == 1,
       "a raising telemetry write dispatches /pay ONCE (was #{app.calls}; re-dispatch = K-622)")
assert(status == 200 && headers == { "content-type" => "application/json" },
       "  … and the app's own status/headers come back unchanged")
assert(body_bytes(body).include?("agt_9f3"),
       "  … and the app's own body comes back unchanged")

# (a2) The reachable production raiser: /auth/register's body buffering. Before
#      the fix this replayed the registration — a SECOND agent minted.
$record_raises = false
app = FakeApp.new { ExplodingBody.new }
boom = nil
begin
  run(app, "/auth/register")
rescue StandardError => e
  boom = e
end
assert(app.calls == 1 && app.registrations == 1,
       "a response body that raises mid-buffering registers ONCE " \
       "(calls=#{app.calls} registrations=#{app.registrations}; 2 = K-622's replayed registration)")
assert(boom.is_a?(BodyBoom),
       "  … and the app's own body failure surfaces instead of being masked as a truncated 200 " \
       "(got #{boom.inspect})")
assert(RECORDED.empty?, "  … and no event is recorded for a response that never completed")

# (b) A telemetry failure on the BUFFERED path still returns the response.
$record_raises = true
app = FakeApp.new { ChunkedBody.new(['{"agent_id":', '"agt_9f3"}']) }
status, headers, body = run(app, "/auth/register")
assert(app.calls == 1, "a raising telemetry write dispatches /auth/register ONCE (was #{app.calls})")
assert(status == 200 && body_bytes(body) == '{"agent_id":"agt_9f3"}',
       "  … and the buffered response is returned intact even though telemetry failed")

# (b2) A raise from the kind lookup — the pre-record half of the post-dispatch
#      region — is swallowed too, and the response is untouched.
$record_raises = false

def with_exploding_kind_lookup
  DemoTelemetry.singleton_class.alias_method(:__real_action_kind_for, :action_kind_for)
  DemoTelemetry.define_singleton_method(:action_kind_for) { |**| raise "verb map exploded" }
  yield
ensure
  DemoTelemetry.singleton_class.alias_method(:action_kind_for, :__real_action_kind_for)
end

with_exploding_kind_lookup do
  app_body = ChunkedBody.new(["x"])
  app = FakeApp.new { app_body }
  status, _headers, body = run(app, "/kiosk/create_order", body: "{}")
  assert(app.calls == 1 && status == 200 && body.equal?(app_body),
         "a raise while classifying the action dispatches once and returns the app's " \
         "ORIGINAL body object untouched (calls=#{app.calls})")
  assert(RECORDED.empty?, "  … and records nothing")
end

$record_raises = false

# ═════════════════════════════════════════════════════════════════════════════
# The /auth/register body buffering is byte-preserving
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── /auth/register response buffering ──"

json = '{"agent_id":"agt_9f3","access_token":"tok","expires_in":3600}'
chunks = [json[0, 17], json[17, 20], json[37..]]
app_body = ChunkedBody.new(chunks)
app = FakeApp.new { app_body }
status, _headers, body = run(app, "/auth/register")

assert(status == 200 && body_bytes(body) == json,
       "the downstream body is byte-for-byte the app's own response")
assert(!body.equal?(app_body),
       "the downstream body is a COPY, not the already-consumed original")
first  = [].tap { |a| body.each { |c| a << c } }.join
second = [].tap { |a| body.each { |c| a << c } }.join
assert(first == json && second == json,
       "the downstream body is re-enumerable — a Rack server may read it more than once")
assert(app_body.closed, "the original body is closed after buffering (Rack contract)")
assert(app_body.enumerations == 1, "the original body is enumerated exactly once")
assert(RECORDED == [{ kind: "registered", agent: "agt_9f3" }],
       "the agent ref is the freshly minted agent_id read out of that body, got #{RECORDED.inspect}")

# A register response that is not JSON must not take the request down.
app = FakeApp.new { ["not json at all"] }
status, _headers, body = run(app, "/auth/register")
assert(app.calls == 1 && status == 200 && body_bytes(body) == "not json at all",
       "a non-JSON register response is dispatched once and returned intact")
assert(RECORDED == [{ kind: "registered", agent: nil }],
       "  … recorded with a nil agent ref rather than raising, got #{RECORDED.inspect}")

# ═════════════════════════════════════════════════════════════════════════════
# What gets recorded, and what does not
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── the recording rules ──"

# Master switch.
ENV["KIOSK_TELEMETRY"] = nil
app = FakeApp.new
run(app, "/kiosk/create_order", body: "{}")
assert(app.calls == 1 && RECORDED.empty?,
       "KIOSK_TELEMETRY unset → pure pass-through, nothing recorded")
ENV["KIOSK_TELEMETRY"] = "1"

# Path filter. On the 0.4 wire a verb is ONE lower-case segment under the
# mount, so the filter is "a legal verb name directly under /kiosk" plus
# /auth/register — everything else is not an activity.
[
  ["/.well-known/kiosk.json",      "GET",  "root discovery"],
  ["/admin/orders",                "POST", "the back-office"],
  ["/kiosk/auth/challenge",        "GET",  "the auth plane (two segments)"],
  ["/kiosk/oauth/token",           "POST", "the device grant (two segments)"],
  ["/kiosk/.well-known/jwks.json", "GET",  "the mount-relative JWKS"],
  ["/kiosk/openapi.json",          "GET",  "the derived description (a dot is not a verb name)"],
  ["/kiosk/schema",                "GET",  "the catalog — a cold start, not an activity"],
  ["/kiosk/Catalog",               "GET",  "an upper-case segment, which cannot be a verb name"],
].each do |path, method, what|
  app = FakeApp.new
  run(app, path, method: method)
  assert(app.calls == 1 && RECORDED.empty?,
         "#{what} (#{method} #{path}) is dispatched once and records nothing")
end

# 2xx only — a 402 pow_required or a 403 gate rejection is not a completed action.
[200, 201, 204, 299].each do |code|
  app = FakeApp.new(status: code)
  run(app, "/kiosk/catalog", method: "GET", bearer: "t")
  assert(RECORDED.size == 1, "a #{code} GET /catalog IS recorded")
end
[302, 400, 402, 403, 404, 422, 500].each do |code|
  app = FakeApp.new(status: code)
  status, = run(app, "/kiosk/catalog", method: "GET", bearer: "t")
  assert(status == code && RECORDED.empty?, "a #{code} GET /catalog is NOT recorded")
end

# The per-app verb map keys on the ACTION NAME, which is now the path segment.
{
  "create_order"        => "ordered",
  "reschedule_delivery" => "scheduled",
  "payment_setup"       => "ran",
  "list_orders"         => "ran",   # unmapped action falls back
}.each do |verb, kind|
  app = FakeApp.new
  run(app, "/kiosk/#{verb}", body: "{}", bearer: "t")
  assert(RECORDED.map { _1[:kind] } == [kind],
         "POST /#{verb} → #{kind.inspect}, got #{RECORDED.map { _1[:kind] }.inspect}")
end

# THE METHOD, NOT THE NAME, DECIDES read-vs-write — the whole point of the 0.4
# classifier, and the reason no body has to be read to apply it.
app = FakeApp.new
run(app, "/kiosk/catalog", method: "GET", bearer: "t")
assert(RECORDED.map { _1[:kind] } == ["browsed"], "GET /catalog → \"browsed\"")
app = FakeApp.new
run(app, "/kiosk/create_order", method: "GET", bearer: "t")
assert(RECORDED.map { _1[:kind] } == ["browsed"],
       "a GET is classified as a read whatever the verb_map says about that name")

{ ["/auth/register", "POST"] => "registered",
  ["/kiosk/pay", "POST"]     => "paid" }.each do |(path, method), kind|
  app = FakeApp.new
  run(app, path, method: method, body: "{}", bearer: "t")
  assert(RECORDED.map { _1[:kind] } == [kind], "#{method} #{path} → #{kind.inspect}")
end

# A demo with NO verb map still records an action as the generic "ran".
app = FakeApp.new
run(app, "/kiosk/create_order", body: "{}", bearer: "t", verb_map: {})
assert(RECORDED.map { _1[:kind] } == ["ran"], "an app with no verb_map records an action as \"ran\"")

# ═════════════════════════════════════════════════════════════════════════════
# Privacy: what identifies the agent
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── the agent ref never carries the raw credential ──"

token = "kiosk_at_super_secret_token_value"
app = FakeApp.new
run(app, "/kiosk/pay", body: "{}", bearer: token)
ref = RECORDED.first[:agent]
assert(ref.is_a?(String) && ref.match?(/\A[0-9a-f]{24}\z/),
       "the bearer agent ref is a 24-hex digest, got #{ref.inspect}")
assert(!ref.include?(token) && !token.include?(ref),
       "the raw bearer token is never the ref")
app = FakeApp.new
run(app, "/kiosk/pay", body: "{}", bearer: token)
assert(RECORDED.first[:agent] == ref, "the ref is STABLE for one agent (distinct-counting works)")
app = FakeApp.new
run(app, "/kiosk/pay", body: "{}", bearer: "#{token}-other")
assert(RECORDED.first[:agent] != ref, "a different agent gets a different ref")

app = FakeApp.new
run(app, "/kiosk/pay", body: "{}")           # no Authorization header at all
assert(app.calls == 1 && RECORDED == [{ kind: "paid", agent: nil }],
       "an unauthenticated call records a nil ref rather than raising, got #{RECORDED.inspect}")

# ═════════════════════════════════════════════════════════════════════════════
# THE REQUEST BODY IS NEVER READ
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── the middleware never touches rack.input ──"

# Through 0.3 the verb name was a BODY field, so this middleware had to read
# and rewind `rack.input` before the app ran — a peek at every write, one
# missed rewind away from handing Rails a consumed stream. On the 0.4 wire the
# name is the path, so the body is not a telemetry input at all.
body_json = '{"items":[{"sku":"milk","qty":2}]}'
app = FakeApp.new
run(app, "/kiosk/create_order", body: body_json, bearer: "t")
assert(app.read_bodies == [body_json],
       "the app reads the FULL request body from position 0 — the middleware never consumed it")
assert(RECORDED.map { _1[:kind] } == ["ordered"],
       "  … and the action was still classified, from the path")

app = FakeApp.new
run(app, "/kiosk/create_order", body: "{not json at all", bearer: "t")
assert(app.calls == 1 && RECORDED.map { _1[:kind] } == ["ordered"],
       "an unparseable body cannot affect classification — it is never parsed")

app = FakeApp.new
run(app, "/kiosk/create_order", bearer: "t")   # no rack.input at all
assert(app.calls == 1 && RECORDED.map { _1[:kind] } == ["ordered"],
       "a request with no rack.input is dispatched once and still classified")

# ═════════════════════════════════════════════════════════════════════════════
if FAILURES.empty?
  puts "\ntelemetry middleware K-622 spec: ALL PASS"
  exit 0
else
  puts "\ntelemetry middleware K-622 spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
