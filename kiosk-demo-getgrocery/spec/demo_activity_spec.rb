# frozen_string_literal: true

# Request spec for GET /demo/activity.json — `app/controllers/demo_activity_controller.rb`,
# the endpoint the kiosk.tech landing tile actually fetches. Run through a real
# boot, in BOTH telemetry modes (that is the point — half the contract is what
# happens when telemetry is OFF):
#
#   KIOSK_TELEMETRY=1 bundle exec rails runner spec/demo_activity_spec.rb   # the endpoint
#                     bundle exec rails runner spec/demo_activity_spec.rb   # its absence
#
# `bundle exec rake demo:telemetry_spec` runs both, in that order.
#
# WHY A BOOT (K-622). The route is drawn, and the middleware inserted, only when
# KIOSK_TELEMETRY=1 at boot time (config/routes.rb, config/initializers/kiosk.rb),
# so "is it there / is it absent" cannot be asserted in-process — it needs two
# processes. Everything else here rides the app's own middleware stack via
# Rack::MockRequest, so no server and no port are involved.
#
# What is pinned:
#   • the response shape the landing tile consumes — counts ONLY, and the exact
#     key set, so no agent detail can start leaking out of `aggregates`;
#   • the two cross-origin/caching headers the tile depends on;
#   • scope=all vs scope=app actually SELECT DIFFERENTLY — asserted by writing
#     rows under two app names and reading the deltas back, not by shape alone;
#   • fetching the tile does not itself record a telemetry event (the
#     middleware's path filter, over the real stack);
#   • with KIOSK_TELEMETRY unset: no route, no middleware, the module not even
#     loaded — the "pure no-op in CI/local flows" the comments claim.
#
# Needs the demo's database (the job-level `demo:setup` in CI), which is where
# the telemetry table's own migration puts it.

require "json"
require "securerandom"
require "rack/mock_request"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

def get(query = nil)
  path = "/demo/activity.json#{query}"
  Rack::MockRequest.new(Rails.application).get(path, "HTTP_HOST" => "localhost")
end

def middleware_wired?
  Rails.application.config.middleware.map { |m| m.klass.to_s }.include?("DemoTelemetryMiddleware")
end

telemetry_on = ENV["KIOSK_TELEMETRY"] == "1"

# K-620 write-target guard, same as demo:telemetry's. The scope assertions below
# WRITE a handful of synthetic rows, and which store they land in is decided by
# an environment variable — one of whose two settings is the SHARED store behind
# the public kiosk.tech landing tile. Refuse that target unless asked by name.
if telemetry_on && !ENV["KIOSK_TELEMETRY_DB_URL"].to_s.empty? && ENV["SEED_SHARED"] != "1"
  abort <<~MSG
    demo_activity_spec refuses to write SYNTHETIC events into the SHARED telemetry
    store: KIOSK_TELEMETRY_DB_URL is set, and that store feeds the public
    kiosk.tech landing tile. Unset it to run against this demo's own database.
  MSG
end

if telemetry_on
  puts "\n── GET /demo/activity.json with KIOSK_TELEMETRY=1 ──"

  # K-714. The store is provisioned ahead of the request — by this demo's own
  # migration locally, by deploy/telemetry-init.sql for the shared hosted one —
  # so nothing here may issue DDL. Watching starts BEFORE the first read: the
  # schema guard it replaced was process-local, so it fired on the first call a
  # fresh process made and on no other, and an assertion placed any later would
  # pass against the very code it exists to rule out.
  ddl = []
  ddl_watch = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
    ddl << payload[:sql].to_s if payload[:sql].to_s.match?(/\A\s*(CREATE|ALTER|DROP)\b/i)
  end

  assert(middleware_wired?, "DemoTelemetryMiddleware is inserted into the middleware stack")

  res = get
  assert(res.status == 200, "the endpoint answers 200, got #{res.status}")
  assert(res.headers["content-type"].to_s.start_with?("application/json"),
         "  … as JSON, got #{res.headers['content-type'].inspect}")

  cache = res.headers["cache-control"].to_s
  assert(cache.include?("public") && cache.include?("max-age=10"),
         "  … cacheable for the tile/CDN: #{cache.inspect} carries public + max-age=10")
  assert(res.headers["access-control-allow-origin"] == "*",
         "  … and cross-origin readable by the kiosk.tech tile, got " \
         "#{res.headers['access-control-allow-origin'].inspect}")

  body = JSON.parse(res.body)
  assert(body.keys.sort == %w[actions_last_hour assistants_active_10m generated_at
                              registered_total scope],
         "the payload is exactly the five documented count/meta keys, got #{body.keys.sort.inspect}")
  assert(body["actions_last_hour"].values.all? { |v| v.is_a?(Integer) } &&
         body["assistants_active_10m"].is_a?(Integer) && body["registered_total"].is_a?(Integer),
         "  … every figure is a COUNT — no agent detail, no PII, nothing per-request")
  assert(body["scope"] == "all", "no ?scope → the all-apps aggregate the landing tile wants")
  assert(JSON.parse(get("?scope=app").body)["scope"] == DemoTelemetry.app_name,
         "?scope=app → this demo's own name")
  assert(JSON.parse(get("?scope=bogus").body)["scope"] == "all",
         "an unrecognised ?scope falls back to the all-apps aggregate, never to an error")

  # ── The two scopes really do select differently ────────────────────────────
  before_app = JSON.parse(get("?scope=app").body)
  before_all = JSON.parse(get.body)

  mine   = 3
  theirs = 2
  other_app = "zz-not-a-real-demo-#{SecureRandom.hex(4)}"
  mine.times   { DemoTelemetry.record(action_kind: "registered", agent: SecureRandom.uuid) }
  theirs.times { DemoTelemetry.record(action_kind: "registered", agent: SecureRandom.uuid, app: other_app) }

  after_app = JSON.parse(get("?scope=app").body)
  after_all = JSON.parse(get.body)

  assert(after_app["registered_total"] - before_app["registered_total"] == mine,
         "scope=app counts only THIS demo's #{mine} new registrations " \
         "(delta #{after_app['registered_total'] - before_app['registered_total']})")
  assert(after_all["registered_total"] - before_all["registered_total"] == mine + theirs,
         "scope=all spans every app in the store — #{mine + theirs} new registrations " \
         "(delta #{after_all['registered_total'] - before_all['registered_total']})")
  assert(after_app["assistants_active_10m"] - before_app["assistants_active_10m"] == mine,
         "scope=app's 10-minute active count moved by the #{mine} distinct new agents")
  assert(after_all["assistants_active_10m"] - before_all["assistants_active_10m"] == mine + theirs,
         "scope=all's did too, across both apps")
  assert(after_app["actions_last_hour"].fetch("registered", 0) -
         before_app["actions_last_hour"].fetch("registered", 0) == mine,
         "the last-hour breakdown moved by the same #{mine} for this app")

  # ── Reading the tile is not itself an event ────────────────────────────────
  # The endpoint rides the app's real middleware stack, so this is the path
  # filter under test, not a unit stub.
  probe = JSON.parse(get.body)
  3.times { get }
  assert(JSON.parse(get.body)["registered_total"] == probe["registered_total"] &&
         JSON.parse(get.body)["actions_last_hour"] == probe["actions_last_hour"],
         "fetching the aggregate records nothing — the tile cannot inflate its own numbers")

  ActiveSupport::Notifications.unsubscribe(ddl_watch)
  assert(ddl.empty?,
         "no DDL anywhere on the read or write path — the table is a migration's, not a " \
         "request's (K-714); saw #{ddl.map { |s| s[0, 60] }.inspect}")
else
  puts "\n── GET /demo/activity.json with KIOSK_TELEMETRY unset ──"

  drawn = Rails.application.routes.routes.any? { |r| r.path.spec.to_s.include?("/demo/activity") }
  assert(!drawn, "the route is not drawn at all")
  assert(get.status == 404, "the endpoint is a 404 by absence, got #{get.status}")
  assert(!middleware_wired?, "DemoTelemetryMiddleware is not in the middleware stack")
  # `defined?(DemoTelemetry)` is not the test: app/services is an autoload-once
  # path, so Zeitwerk registers the constant either way. Whether the FILE ran is.
  assert($LOADED_FEATURES.none? { |f| f.end_with?("app/services/demo_telemetry.rb") },
         "app/services/demo_telemetry.rb is never even loaded — a true no-op")
end

if FAILURES.empty?
  puts "\ndemo/activity.json spec (KIOSK_TELEMETRY=#{telemetry_on ? '1' : 'unset'}): ALL PASS"
  exit 0
else
  puts "\ndemo/activity.json spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
