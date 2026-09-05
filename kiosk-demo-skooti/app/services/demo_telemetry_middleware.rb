# frozen_string_literal: true

require "digest"
require "json"

# Rack middleware that records ONE telemetry event per SUCCESSFUL wire action.
# Inserted only when KIOSK_TELEMETRY=1 (see the demo's config/initializers),
# and a pass-through otherwise.
#
# Privacy: the distinct-count ref is a hash of the request Bearer token — the
# token itself is never stored — or, on /auth/register where there is no bearer
# yet, of the response `agent_id`. Both go through DemoTelemetry.agent_hash,
# which salts per app, so nothing persisted is joinable across demos.
class DemoTelemetryMiddleware
  # @param app [Rack app]
  # @param verb_map [Hash] concrete-verb → generic-kind override for actions
  def initialize(app, verb_map: {})
    @app = app
    @verb_map = verb_map
  end

  # Telemetry must never break a wire action, and the safe recovery differs on
  # each side of the dispatch. BEFORE the app runs it is to hand the request to
  # the app. AFTER it has run the only safe recovery is the response already in
  # hand: calling the app again does not retry a request, it DISPATCHES A SECOND
  # ONE, and on /auth/register that mints a second agent. So every
  # `@app.call` below except one is an early return in the pre-dispatch region,
  # and nothing under the single dispatch line may reach one.
  def call(env)
    # ── Before the app runs ───────────────────────────────────────────────
    begin
      return @app.call(env) unless DemoTelemetry.enabled?

      path   = env["PATH_INFO"].to_s
      method = env["REQUEST_METHOD"].to_s
      # Everything the classifier needs is in the request LINE; no body is read
      # on any path.
      kind = best_effort do
        DemoTelemetry.action_kind_for(path: path, method: method, verb_map: @verb_map)
      end
      return @app.call(env) if kind.nil?
    rescue StandardError => e
      warn "[demo_telemetry] middleware error before dispatch (ignored): #{e.class}: #{e.message}"
      return @app.call(env)
    end

    # ── The one and only dispatch ─────────────────────────────────────────
    status, headers, body = @app.call(env)

    # Only record on success (2xx). A 402 pow_required / 403 gate rejection is
    # not a completed action.
    return [status, headers, body] unless status.to_i >= 200 && status.to_i < 300

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

  # Run one piece of telemetry work after the app has answered. A failure here
  # is swallowed — the request is not telemetry's to break — and the caller
  # carries on with the response it already holds. There is no retry at this
  # point and nothing here may look like one.
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
  # Deliberately NOT best_effort: a body that raises mid-enumeration is the
  # APP's failure, and swallowing it here would turn that into a silently
  # TRUNCATED 200 — worse than the failure it hides. So it propagates.
  def buffer(body)
    buffered = []
    body.each { |c| buffered << c }
    buffered
  ensure
    body.close if body.respond_to?(:close)
  end

  # register: distinct-count ref = the freshly minted agent_id (from the
  # buffered JSON response). Never the raw key.
  def register_agent_ref(buffered_chunks)
    JSON.parse(buffered_chunks.join)["agent_id"]
  rescue StandardError
    nil
  end

  # non-register verbs: a stable per-agent ref = hash of the Bearer token,
  # hashed again (salted per app) in agent_hash. The raw token never leaves here.
  def bearer_agent_ref(env)
    auth = env["HTTP_AUTHORIZATION"].to_s
    return nil unless auth.start_with?("Bearer ")

    Digest::SHA256.hexdigest(auth[7..].to_s)[0, 24]
  rescue StandardError
    nil
  end
end
