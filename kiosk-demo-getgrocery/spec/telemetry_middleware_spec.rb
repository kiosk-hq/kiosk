# frozen_string_literal: true

# Standalone (no rails boot, no DB, no network) unit spec for
# `lib/demo_telemetry.rb`'s Rack middleware — `DemoTelemetryMiddleware`. Run:
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
#   • the recording rules themselves: the four-path filter, 2xx-only, the
#     per-app verb_map, the register/bearer agent refs, and that the request
#     body is left rewound for the app.
# DB-free on purpose: DemoTelemetry.record is stubbed, so this needs neither
# Postgres nor the telemetry table (getgrocery ships no rspec — same plain-ruby
# shape as spec/delivery_slots_spec.rb and spec/cashier_order_ref_spec.rb).

require "json"
require "stringio"
# demo_telemetry.rb declares `class DemoTelemetryRecord < ActiveRecord::Base`
# at load time. Loading the constant costs ~0.2 s and opens NO connection.
require "active_record"

ENV["KIOSK_TELEMETRY"] = "1"
require_relative "../lib/demo_telemetry"

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

def env_for(path, body: nil, bearer: nil)
  env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => path }
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

def run(app, path, body: nil, bearer: nil, verb_map: VERB_MAP)
  RECORDED.clear
  DemoTelemetryMiddleware.new(app, verb_map: verb_map).call(env_for(path, body: body, bearer: bearer))
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
  status, _headers, body = run(app, "/kiosk/run", body: '{"name":"create_order"}')
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
run(app, "/kiosk/run", body: '{"name":"create_order"}')
assert(app.calls == 1 && RECORDED.empty?,
       "KIOSK_TELEMETRY unset → pure pass-through, nothing recorded")
ENV["KIOSK_TELEMETRY"] = "1"

# Path filter: only the four write-ish wire surfaces are candidates.
[
  ["/kiosk/orders",            "a non-wire path"],
  ["/.well-known/kiosk.json",  "discovery"],
  ["/kiosk/runner",            "a path that merely CONTAINS 'run'"],
  ["/admin/orders",            "the back-office"],
].each do |path, what|
  app = FakeApp.new
  run(app, path)
  assert(app.calls == 1 && RECORDED.empty?, "#{what} (#{path}) is dispatched once and records nothing")
end

# 2xx only — a 402 pow_required or a 403 gate rejection is not a completed action.
[200, 201, 204, 299].each do |code|
  app = FakeApp.new(status: code)
  run(app, "/kiosk/query", body: '{"name":"catalog"}', bearer: "t")
  assert(RECORDED.size == 1, "a #{code} /query IS recorded")
end
[302, 400, 402, 403, 404, 422, 500].each do |code|
  app = FakeApp.new(status: code)
  status, = run(app, "/kiosk/query", body: '{"name":"catalog"}', bearer: "t")
  assert(status == code && RECORDED.empty?, "a #{code} /query is NOT recorded")
end

# The per-app verb map for /run, and the fixed kinds for the other three.
{
  "create_order"        => "ordered",
  "reschedule_delivery" => "scheduled",
  "payment_setup"       => "ran",
  "list_orders"         => "ran",   # unmapped verb falls back
  nil                   => "ran",   # body with no `name`
}.each do |verb, kind|
  app = FakeApp.new
  run(app, "/kiosk/run", body: JSON.generate(verb ? { "name" => verb } : { "x" => 1 }), bearer: "t")
  assert(RECORDED.map { _1[:kind] } == [kind],
         "/run #{verb.inspect} → #{kind.inspect}, got #{RECORDED.map { _1[:kind] }.inspect}")
end
{ "/auth/register" => "registered", "/kiosk/query" => "browsed", "/kiosk/pay" => "paid" }
  .each do |path, kind|
  app = FakeApp.new
  run(app, path, body: "{}", bearer: "t")
  assert(RECORDED.map { _1[:kind] } == [kind], "#{path} → #{kind.inspect}")
end

# A demo with NO verb map still records /run as the generic "ran".
app = FakeApp.new
run(app, "/kiosk/run", body: '{"name":"create_order"}', bearer: "t", verb_map: {})
assert(RECORDED.map { _1[:kind] } == ["ran"], "an app with no verb_map records /run as \"ran\"")

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
# The request body is left exactly as the app expects it
# ═════════════════════════════════════════════════════════════════════════════
puts "\n── rack.input is rewound for the app ──"

body_json = '{"name":"create_order","arguments":{"items":[{"sku":"milk","qty":2}]}}'
app = FakeApp.new
run(app, "/kiosk/run", body: body_json, bearer: "t")
assert(app.read_bodies == [body_json],
       "the app still reads the FULL request body after the middleware peeked at the verb")

app = FakeApp.new
run(app, "/kiosk/run", body: "{not json", bearer: "t")
assert(app.calls == 1 && RECORDED.map { _1[:kind] } == ["ran"],
       "an unparseable /run body falls back to \"ran\" instead of raising")

app = FakeApp.new
run(app, "/kiosk/run", bearer: "t")          # no rack.input at all
assert(app.calls == 1 && RECORDED.map { _1[:kind] } == ["ran"],
       "a /run with no rack.input is dispatched once and falls back to \"ran\"")

# ═════════════════════════════════════════════════════════════════════════════
if FAILURES.empty?
  puts "\ntelemetry middleware K-622 spec: ALL PASS"
  exit 0
else
  puts "\ntelemetry middleware K-622 spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
