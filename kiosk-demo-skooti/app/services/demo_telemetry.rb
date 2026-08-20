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
# app/services/ (the same copy-not-symlink pattern the stub IdPs use) and
# driven by {DemoTelemetryMiddleware}, its path-matching sibling in this
# directory — split out of this file (K-502) so Zeitwerk can autoload the
# middleware by name and the initializer needs no `require`.
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
  # "booked"; skooti's reserve → "reserved"). Unknown actions fall back to
  # "ran".
  #
  # ON THE 0.4 WIRE THE PATH IS THE VERB AND THE METHOD IS THE KIND. Through
  # 0.3 this read the last path segment (`/query`, `/run`, `/pay`) and, for a
  # write, dug the verb NAME out of the JSON body — which meant reading and
  # rewinding `rack.input` before the app ran. Now `GET <mount>/<name>` is a
  # read and `POST <mount>/<name>` is a write, so both facts are in the request
  # line and no body is touched at all.
  #
  # @param path [String] request path (e.g. "/kiosk/create_order")
  # @param method [String] the HTTP method
  # @param verb_map [Hash] app override: { "create_order" => "ordered", ... }
  # @return [String, nil]
  def action_kind_for(path:, method: "POST", verb_map: {})
    return "registered" if path.match?(%r{/auth/register\z})

    name = wire_verb_name(path)
    return nil if name.nil?
    return "paid" if name == "pay"
    # `schema` is a catalog read, not an activity: counting it as "browsed"
    # would inflate the board with every assistant's cold start.
    return nil if name == "schema"

    method.to_s.upcase == "GET" ? "browsed" : verb_map.fetch(name) { "ran" }
  end

  # The single path segment under the mount, or nil when the path is not a
  # verb call. Excludes the auth/oauth/agents planes (two segments), the
  # mount-relative JWKS and `openapi.json` (a dot is not legal in a verb
  # name), and anything outside the mount entirely.
  def wire_verb_name(path)
    mount = begin
      Kiosk.configuration.mount_path
    rescue StandardError
      "/kiosk"
    end
    match = path.match(%r{\A#{Regexp.escape(mount.to_s)}/([a-z][a-z0-9_]*)\z})
    match && match[1]
  end
end
