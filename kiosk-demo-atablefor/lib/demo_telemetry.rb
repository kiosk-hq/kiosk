# frozen_string_literal: true

require "digest"
require "json"

# Shared, app-layer live-activity telemetry for the hosted Kiosk demos
# OPT-IN and privacy-safe.
#
# ── What it is ────────────────────────────────────────────────────────────
# An append-only `demo_telemetry_events(app, action_kind, agent_hash, at)`
# store plus aggregate readers. Each demo records ONE row per wire action; the
# landing tile (or a demo's own /demo/activity.json) reads aggregate counts.
#
# ── Why it lives here, not in kiosk-core ──────────────────────────────────
# Satellite neutrality: telemetry is an app-layer concern. kiosk-core /
# kiosk-server never learn about it. This module is copied into each demo's
# lib/ (the same copy-not-symlink pattern the stub IdPs use) and included via
# the Rack middleware below.
#
# ── Opt-in / off by default ───────────────────────────────────────────────
# Nothing happens unless KIOSK_TELEMETRY=1. Unset (CI, local flows) → the
# middleware is a pass-through and no table is touched. So existing demo flows
# are byte-identical to before.
#
# ── One shared store in the hosted deploy, local-testable ─────────────────
# * Hosted: set KIOSK_TELEMETRY_DB_URL to the shared `kiosk_demo_telemetry`
#   Postgres — every app writes/reads the ONE table there, so the landing
#   aggregate spans all demos.
# * Local / CI: unset → the demo's own ActiveRecord connection is used and the
#   table is created idempotently in that DB. Fully testable without any
#   shared infra.
#
# ── Privacy properties (honors "no cross-provider tracking") ──────────────
# * NO PII, NO raw agent id, NO IP, NO user-agent stored — only a per-app
#   SALTED hash of the agent, used solely for distinct-counts.
# * agent_hash = SHA256(app ‖ per-app-salt ‖ agent_id). The salt is
#   per-app (KIOSK_TELEMETRY_SALT, or a per-app default), so the SAME agent
#   hashing at two demos produces DIFFERENT, non-joinable hashes — the hash
#   cannot be correlated across apps. Joining an agent across demos would BE
#   the cross-provider tracking Kiosk forbids; this makes it impossible by
#   construction.
# * Aggregates are counts only; the agent_hash is never surfaced.
module DemoTelemetry
  TABLE = "demo_telemetry_events"

  # Generic, provider-neutral action kinds. A demo maps its concrete verbs
  # onto these so the aggregate reads the same across every vertical.
  ACTION_KINDS = %w[
    registered browsed ordered booked reserved paid scheduled cancelled ran
  ].freeze

  module_function

  # Master switch. Everything is a no-op unless this is true.
  def enabled?
    ENV["KIOSK_TELEMETRY"] == "1"
  end

  # The app name this process reports under (the provider/demo slug).
  # Defaults to the configured owner name, else "demo".
  def app_name
    ENV["KIOSK_TELEMETRY_APP"] ||
      (Kiosk.configuration.owner.is_a?(Hash) && Kiosk.configuration.owner[:name]) ||
      "demo"
  rescue StandardError
    ENV["KIOSK_TELEMETRY_APP"] || "demo"
  end

  # Per-app salt. Per-app by construction so agent_hash is NOT joinable across
  # apps. A deployment sets KIOSK_TELEMETRY_SALT per app; the default folds the
  # app name in so two demos in one dev DB still don't collide.
  def salt
    ENV["KIOSK_TELEMETRY_SALT"] || "kiosk-demo-telemetry-#{app_name}"
  end

  # SHA256(app ‖ salt ‖ agent) truncated to 32 hex chars. Distinct-count only;
  # never reversed, never surfaced, never joined across apps.
  # @param agent [String, nil] the raw agent/principal id (never stored)
  def agent_hash(agent)
    Digest::SHA256.hexdigest("#{app_name}\x1f#{salt}\x1f#{agent}")[0, 32]
  end

  # The ActiveRecord connection to write/read telemetry on. In the hosted
  # deploy KIOSK_TELEMETRY_DB_URL points every app at the ONE shared DB (via a
  # dedicated pool on DemoTelemetryRecord, so telemetry writes never contend
  # with request transactions); unset falls back to the app's own connection
  # (local/CI testable, single DB).
  def connection
    if (url = ENV["KIOSK_TELEMETRY_DB_URL"]) && !url.empty?
      DemoTelemetryRecord.establish_connection(url) unless DemoTelemetryRecord.connected?
      DemoTelemetryRecord.connection
    else
      ActiveRecord::Base.connection
    end
  end

  # Idempotent table creation — so demos using db:schema:load (structure.sql,
  # not db:migrate) still get the table without regenerating 7 structure.sql
  # files. Safe to call repeatedly; a no-op once the table exists. For the
  # hosted shared-telemetry DB, deploy/telemetry-init.sql provisions the same shape.
  def ensure_schema!(conn = connection)
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{TABLE} (
        id          bigserial PRIMARY KEY,
        app         text        NOT NULL,
        action_kind text        NOT NULL,
        agent_hash  text        NOT NULL,
        at          timestamptz NOT NULL DEFAULT now()
      )
    SQL
    conn.execute("CREATE INDEX IF NOT EXISTS idx_#{TABLE}_at ON #{TABLE} (at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_#{TABLE}_app_at ON #{TABLE} (app, at)")
    nil
  end

  # Record ONE event. No-op unless enabled?. Best-effort: telemetry must never
  # break a wire action, so any failure is swallowed (logged to $stderr).
  #
  # @param action_kind [String] one of ACTION_KINDS (coerced/validated)
  # @param agent [String, nil]  raw agent id — hashed, never stored raw
  # @param app [String]         defaults to app_name
  # @param at  [Time]           event time (default now)
  def record(action_kind:, agent: nil, app: app_name, at: Time.now)
    return unless enabled?

    kind = action_kind.to_s
    kind = "ran" unless ACTION_KINDS.include?(kind)
    conn = connection
    ensure_schema!(conn) unless @schema_ready
    @schema_ready = true
    conn.execute(<<~SQL)
      INSERT INTO #{TABLE} (app, action_kind, agent_hash, at)
      VALUES (
        #{conn.quote(app.to_s)},
        #{conn.quote(kind)},
        #{conn.quote(agent_hash(agent))},
        #{conn.quote(at.utc.iso8601)}::timestamptz
      )
    SQL
    nil
  rescue StandardError => e
    warn "[demo_telemetry] record failed (ignored): #{e.class}: #{e.message}"
    nil
  end

  # Privacy-safe aggregates for the landing tile / a demo's activity.json.
  #
  # @param app [String, nil] scope to one app; nil = ALL apps (the landing
  #   aggregate). The hosted shared DB holds every app's rows.
  # @return [Hash] {
  #   assistants_active_10m:  distinct agent_hash with an event < 10 min,
  #   registered_total:       count of 'registered' events (all time),
  #   actions_last_hour:      { kind => count } over the last hour,
  #   generated_at:           iso8601,
  #   scope:                  app || "all",
  # }
  def aggregates(app: nil)
    conn = connection
    ensure_schema!(conn) unless @schema_ready
    @schema_ready = true
    where_app = app ? "AND app = #{conn.quote(app.to_s)}" : ""
    base_app  = app ? "WHERE app = #{conn.quote(app.to_s)}" : ""

    active = conn.execute(
      "SELECT COUNT(DISTINCT agent_hash) AS n FROM #{TABLE} " \
      "WHERE at > now() - interval '10 minutes' #{where_app}"
    ).first["n"].to_i

    registered = conn.execute(
      "SELECT COUNT(*) AS n FROM #{TABLE} " \
      "WHERE action_kind = 'registered' #{where_app}"
    ).first["n"].to_i

    rows = conn.execute(
      "SELECT action_kind, COUNT(*) AS n FROM #{TABLE} " \
      "WHERE at > now() - interval '1 hour' #{where_app} " \
      "GROUP BY action_kind ORDER BY action_kind"
    ).to_a
    by_kind = rows.each_with_object({}) { |r, h| h[r["action_kind"]] = r["n"].to_i }

    {
      assistants_active_10m: active,
      registered_total:      registered,
      actions_last_hour:     by_kind,
      generated_at:          Time.now.utc.iso8601,
      scope:                 app || "all",
    }
  rescue StandardError => e
    warn "[demo_telemetry] aggregates failed: #{e.class}: #{e.message}"
    { assistants_active_10m: 0, registered_total: 0, actions_last_hour: {},
      generated_at: Time.now.utc.iso8601, scope: app || "all", error: e.message }
  end

  # Seed/simulate N synthetic events across the action kinds and M distinct
  # synthetic agents, so the endpoint + landing tile can be demonstrated before
  # real deploy traffic. Timestamps are jittered within the last hour so the
  # 10-min-active and last-hour buckets both populate.
  #
  # @return [Integer] rows written
  def simulate!(events: 40, agents: 8, app: app_name)
    ensure_schema!
    require "securerandom"
    kinds = %w[registered browsed ordered booked reserved paid]
    now = Time.now
    written = 0
    events.times do |i|
      agent = "sim-agent-#{i % agents}"
      kind  = kinds[i % kinds.size]
      # Half the rows within the last 8 min (feed the 10-min active bucket).
      age_s = i.even? ? rand(0..480) : rand(0..3300)
      record(action_kind: kind, agent: agent, app: app, at: now - age_s)
      written += 1
    end
    written
  end

  # Map a wire request → a generic action_kind (or nil to skip). The optional
  # per-app override maps concrete action verb names onto ACTION_KINDS so the
  # aggregate reads the same across verticals (e.g. getgrocery's create_order →
  # "ordered", reschedule_delivery → "scheduled"; atablefor's book_table →
  # "booked"; skooti's reserve → "reserved"). Unknown run-verbs fall back to
  # "ran".
  #
  # @param path [String] request path (e.g. "/kiosk/run")
  # @param verb [String, nil] the `name` field of a run/query body
  # @param verb_map [Hash] app override: { "create_order" => "ordered", ... }
  # @return [String, nil]
  def action_kind_for(path:, verb: nil, verb_map: {})
    case path
    when %r{/auth/register\z} then "registered"
    when %r{/query\z}         then "browsed"
    when %r{/pay\z}           then "paid"
    when %r{/run\z}
      verb_map.fetch(verb.to_s) { "ran" }
    end
  end
end

# Throwaway AR model that binds to the shared telemetry DB URL when the hosted
# deploy sets KIOSK_TELEMETRY_DB_URL. Unused in the local/CI single-DB path.
class DemoTelemetryRecord < ActiveRecord::Base
  self.abstract_class = true
end

# Rack middleware that records ONE telemetry event per SUCCESSFUL wire action.
# Inserted into the demo's middleware stack ONLY when KIOSK_TELEMETRY=1 (see
# the demo's config/initializers). A pass-through otherwise, so CI/local flows
# are unaffected.
#
# Privacy: the agent is identified for distinct-counting by hashing the request
# Bearer token (a stable per-agent credential) — the token is NEVER stored; on
# /auth/register (no bearer yet) the response `agent_id` is used. Both go
# through DemoTelemetry.agent_hash (per-app salted), so no raw id and no
# cross-app-joinable value is ever persisted.
class DemoTelemetryMiddleware
  # @param app [Rack app]
  # @param verb_map [Hash] concrete-verb → generic-kind override for /run
  def initialize(app, verb_map: {})
    @app = app
    @verb_map = verb_map
  end

  # Telemetry must never break a wire action — but "never break it" has TWO
  # different safe recoveries, and using the wrong one is how K-622 happened.
  # BEFORE the app has run, the safe recovery is to hand the request to the app.
  # AFTER it has run, the ONLY safe recovery is the response already in hand:
  # calling the app again does not retry a failed request, it DISPATCHES A
  # SECOND ONE. On /auth/register that mints a second agent. So `@app.call`
  # appears exactly twice below, both of them above the single dispatch line,
  # and nothing under that line may reach it.
  def call(env)
    # ── Before the app runs ───────────────────────────────────────────────
    begin
      return @app.call(env) unless DemoTelemetry.enabled?

      path = env["PATH_INFO"].to_s
      # Only the four write-ish wire surfaces are candidates; skip everything
      # else (discovery, JWKS, admin, home) without reading the body.
      return @app.call(env) unless path.match?(%r{/(auth/register|query|run|pay)\z})

      # Reads (and rewinds) rack.input, so it MUST happen before the app.
      verb = run_verb(env, path)
    rescue StandardError => e
      warn "[demo_telemetry] middleware error before dispatch (ignored): #{e.class}: #{e.message}"
      return @app.call(env)
    end

    # ── The one and only dispatch ─────────────────────────────────────────
    status, headers, body = @app.call(env)

    # Only record on success (2xx). A 402 pow_required / 403 gate rejection is
    # not a completed action.
    return [status, headers, body] unless status.to_i >= 200 && status.to_i < 300

    kind = best_effort { DemoTelemetry.action_kind_for(path: path, verb: verb, verb_map: @verb_map) }
    return [status, headers, body] unless kind

    # For /auth/register we need the response agent_id, so buffer the body once
    # and hand a re-enumerable copy downstream (safe for Rack). For the other
    # verbs the agent comes from the request Bearer, so no body read is needed.
    if path.end_with?("/auth/register")
      buffered = buffer(body)
      best_effort { DemoTelemetry.record(action_kind: kind, agent: register_agent_ref(buffered)) }
      [status, headers, buffered]
    else
      best_effort { DemoTelemetry.record(action_kind: kind, agent: bearer_agent_ref(env)) }
      [status, headers, body]
    end
  end

  private

  # Run one piece of telemetry work after the app has already answered. A
  # failure here is swallowed (the request is not telemetry's to break) and the
  # caller carries on with the response it is already holding. There is no
  # "retry" at this point and there must never look like one.
  def best_effort
    yield
  rescue StandardError => e
    warn "[demo_telemetry] telemetry error after dispatch (ignored): #{e.class}: #{e.message}"
    nil
  end

  # Read the app's response body into an Array so /auth/register's agent_id can
  # be recovered and a re-enumerable copy handed downstream. Closes the original
  # either way (Rack contract: whoever consumes a body closes it).
  #
  # Deliberately NOT best_effort. A body that raises mid-enumeration is the
  # APP's failure, not telemetry's — it would have raised in the server just the
  # same — and swallowing it here would turn that failure into a silently
  # TRUNCATED 200, which is worse than the failure it hides. So it propagates.
  # What must never happen, and what K-622 was, is "recovering" by dispatching
  # the request again.
  def buffer(body)
    buffered = []
    body.each { |c| buffered << c }
    buffered
  ensure
    body.close if body.respond_to?(:close)
  end

  # Extract the `name` verb from a /run (or /query) JSON body without consuming
  # the stream for the downstream app (rewind after read).
  def run_verb(env, path)
    return nil unless path.end_with?("/run") || path.end_with?("/query")

    input = env["rack.input"]
    return nil unless input

    raw = input.read
    input.rewind
    return nil if raw.nil? || raw.empty?

    JSON.parse(raw)["name"]
  rescue StandardError
    nil
  end

  # register: distinct-count ref = the freshly minted agent_id (from the
  # buffered JSON response). Never the raw key.
  def register_agent_ref(buffered_chunks)
    JSON.parse(buffered_chunks.join)["agent_id"]
  rescue StandardError
    nil
  end

  # non-register verbs: a stable per-agent ref = hash of the Bearer token. The
  # token is hashed here (short) and hashed again (salted per app) in
  # agent_hash — the raw token is never persisted or passed further.
  def bearer_agent_ref(env)
    auth = env["HTTP_AUTHORIZATION"].to_s
    return nil unless auth.start_with?("Bearer ")

    Digest::SHA256.hexdigest(auth[7..].to_s)[0, 24]
  rescue StandardError
    nil
  end
end
