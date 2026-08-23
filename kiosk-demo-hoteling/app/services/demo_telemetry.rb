# frozen_string_literal: true

require "digest"
require "json"

# App-layer live-activity telemetry for the hosted demos: one append-only row
# per wire action, read back as aggregate counts by each demo's
# /demo/activity.json and by the kiosk.tech landing tile.
#
# It lives in the app rather than in kiosk-core because telemetry is an
# app-layer concern and the engine stays neutral about it — which is why this
# file is COPIED into each demo's app/services/. {DemoTelemetryMiddleware}, its
# sibling in this directory, is what calls it.
#
# OFF unless KIOSK_TELEMETRY=1: unset (CI, local flows) the middleware is a
# pass-through and nothing here is even loaded.
#
# The store is the demo's own database, or — in the hosted deploy — the ONE
# shared database KIOSK_TELEMETRY_DB_URL names, so the landing aggregate can
# span every demo. Both are provisioned ahead of the request: the own database
# by db/migrate/20260823000001_create_demo_telemetry_events.rb, the shared one
# by deploy/telemetry-init.sql.
#
# PRIVACY. No PII, no raw agent id, no IP, no user-agent. The only agent column
# is agent_hash, a SHA-256 over (app, salt, agent_id), used for distinct-counts
# and never surfaced. The salt is PER APP, so one assistant hashes to different
# values at two demos and the rows cannot be joined — joining an agent across
# operators would BE the cross-provider tracking Kiosk forbids, and a per-app
# salt makes it impossible rather than merely disallowed.
module DemoTelemetry
  TABLE = "demo_telemetry_events"

  # Provider-neutral kinds: each demo maps its own verbs onto these so the
  # aggregate reads the same across verticals.
  ACTION_KINDS = %w[
    registered browsed ordered booked reserved paid scheduled cancelled ran
  ].freeze

  module_function

  # Master switch. Everything is a no-op unless this is true.
  def enabled?
    ENV["KIOSK_TELEMETRY"] == "1"
  end

  # The app name this process reports under (the provider/demo slug).
  def app_name
    ENV["KIOSK_TELEMETRY_APP"] ||
      (Kiosk.configuration.owner.is_a?(Hash) && Kiosk.configuration.owner[:name]) ||
      "demo"
  rescue StandardError
    ENV["KIOSK_TELEMETRY_APP"] || "demo"
  end

  # Per-app by construction: the default folds the app name in, so two demos
  # sharing one dev database still hash the same agent differently.
  def salt
    ENV["KIOSK_TELEMETRY_SALT"] || "kiosk-demo-telemetry-#{app_name}"
  end

  # Distinct-count handle only: never reversed, never surfaced, never joined.
  # @param agent [String, nil] the raw agent/principal id (never stored)
  def agent_hash(agent)
    Digest::SHA256.hexdigest("#{app_name}\x1f#{salt}\x1f#{agent}")[0, 32]
  end

  # The shared store gets its own pool (via DemoTelemetryRecord) so telemetry
  # writes never contend with request transactions.
  def connection
    if (url = ENV["KIOSK_TELEMETRY_DB_URL"]) && !url.empty?
      DemoTelemetryRecord.establish_connection(url) unless DemoTelemetryRecord.connected?
      DemoTelemetryRecord.connection
    else
      ActiveRecord::Base.connection
    end
  end

  # Every caller value reaches the server as a bind parameter; nothing is
  # spliced into a statement.
  def bind(name, value)
    ActiveRecord::Relation::QueryAttribute.new(name, value, ActiveModel::Type::String.new)
  end

  # Record ONE event. Best-effort: telemetry must never break a wire action, so
  # any failure is swallowed after a line on $stderr.
  #
  # @param action_kind [String] one of ACTION_KINDS (unknown values become "ran")
  # @param agent [String, nil]  raw agent id — hashed, never stored raw
  # @param app [String]         defaults to app_name
  # @param at  [Time]           event time (default now)
  def record(action_kind:, agent: nil, app: app_name, at: Time.now)
    return unless enabled?

    kind = action_kind.to_s
    kind = "ran" unless ACTION_KINDS.include?(kind)
    connection.exec_insert(
      "INSERT INTO #{TABLE} (app, action_kind, agent_hash, at) " \
      "VALUES ($1, $2, $3, $4::timestamptz)",
      "DemoTelemetry record",
      [bind("app", app.to_s), bind("action_kind", kind),
       bind("agent_hash", agent_hash(agent)), bind("at", at.utc.iso8601)]
    )
    nil
  rescue StandardError => e
    warn "[demo_telemetry] record failed (ignored): #{e.class}: #{e.message}"
    nil
  end

  # Counts only, for the tile and for /demo/activity.json.
  #
  # @param app [String, nil] scope to one app; nil = every app in the store,
  #   which is the aggregate the landing tile wants.
  # @return [Hash] assistants_active_10m, registered_total, actions_last_hour,
  #   generated_at, scope
  def aggregates(app: nil)
    conn  = connection
    # One statement shape for both scopes: a NULL bind means "every app".
    scope = bind("app", app&.to_s)

    active = conn.exec_query(
      "SELECT COUNT(DISTINCT agent_hash) AS n FROM #{TABLE} " \
      "WHERE at > now() - interval '10 minutes' AND ($1::text IS NULL OR app = $1)",
      "DemoTelemetry active", [scope]
    ).first["n"].to_i

    registered = conn.exec_query(
      "SELECT COUNT(*) AS n FROM #{TABLE} " \
      "WHERE action_kind = 'registered' AND ($1::text IS NULL OR app = $1)",
      "DemoTelemetry registered", [scope]
    ).first["n"].to_i

    rows = conn.exec_query(
      "SELECT action_kind, COUNT(*) AS n FROM #{TABLE} " \
      "WHERE at > now() - interval '1 hour' AND ($1::text IS NULL OR app = $1) " \
      "GROUP BY action_kind ORDER BY action_kind",
      "DemoTelemetry by kind", [scope]
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

  # Seed synthetic events so the endpoint and the tile can be shown before real
  # traffic exists. Timestamps are jittered within the last hour, half of them
  # inside 8 minutes, so both the 10-minute and the last-hour buckets populate.
  #
  # @return [Integer] rows written
  def simulate!(events: 40, agents: 8, app: app_name)
    kinds = %w[registered browsed ordered booked reserved paid]
    now = Time.now
    written = 0
    events.times do |i|
      agent = "sim-agent-#{i % agents}"
      kind  = kinds[i % kinds.size]
      age_s = i.even? ? rand(0..480) : rand(0..3300)
      record(action_kind: kind, agent: agent, app: app, at: now - age_s)
      written += 1
    end
    written
  end

  # Map a wire request onto a generic action_kind, or nil to skip it. On the 0.4
  # wire both facts are in the request line — the path IS the verb and the
  # method is the kind — so no request body is read or rewound here.
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
    # `schema` is a catalog read, not an activity: counting it would inflate the
    # board with every assistant's cold start.
    return nil if name == "schema"

    method.to_s.upcase == "GET" ? "browsed" : verb_map.fetch(name) { "ran" }
  end

  # The single path segment under the mount, or nil when the path is not a verb
  # call. Excludes the auth/oauth/agents planes (two segments), the
  # mount-relative JWKS and `openapi.json` (a dot is not legal in a verb name),
  # and anything outside the mount.
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
