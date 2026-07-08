# frozen_string_literal: true

require "json"

Rails.application.routes.draw do
  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  root "home#index"

  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints (ADR-0005): one per verb, HTTP method = semantics.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  post "/kiosk/query",                             to: "kiosk/server/wire#query"
  post "/kiosk/run",                               to: "kiosk/server/wire#run"
  post "/kiosk/pay",                               to: "kiosk/server/wire#pay"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
  get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
  post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
  post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
  post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"

  # /.well-known/kiosk.json discovery endpoint — built on the fly from
  # Kiosk.configuration. Inlined here since kiosk-server doesn't yet
  # ship a controller for it.
  # well-known = the machine-readable HANDSHAKE: who/where/which version + issuer
  # (the AP2 `iss` anchor) + auth, served at the guessable conventional URL. It
  # is NOT the surface — it points to the REST verbs (schema/query/run/pay),
  # which carry the protocol + the live queries/actions. The `verbs` summary is
  # DERIVED from the actually implemented verbs (no hardcoded capability list),
  # so discovery and the live surface never drift.
  get "/.well-known/kiosk.json", to: ->(env) {
    base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
    doc      = Kiosk::Server::WellKnown.build(base_url: base_url)
    endpoint = doc[:kiosk][:endpoint]
    doc[:kiosk].delete(:capabilities)          # drop the static capability list
    doc[:kiosk][:verbs] = Kiosk::Server::Executor::IMPLEMENTED_VERBS  # the truth
    doc[:kiosk][:routing] = {                                         # ADR-0005
      "schema" => { "method" => "GET",  "path" => "#{endpoint}/schema" },
      "query"  => { "method" => "POST", "path" => "#{endpoint}/query" },
      "run"    => { "method" => "POST", "path" => "#{endpoint}/run" },
      "pay"    => { "method" => "POST", "path" => "#{endpoint}/pay" },
    }
    [200, { "content-type" => "application/json" }, [JSON.generate(doc)]]
  }

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders

  # ─── E2e-only test fixtures ──────────────────────────────────────────
  # Simulates user approval / denial at /oauth/device/verify. The real
  # consent-screen UI (Kiosk-branded HTML + Devise current_user) is a
  # provider responsibility — Kiosk ships the {DeviceVerification}
  # state-machine helpers; the host's controller wires them up. This
  # fixture proves the helper works end-to-end without a browser
  # in the loop.
  if Rails.env.development?
    handle_verification = ->(decision, user_code, user_id) do
      begin
        case decision
        when "approve"
          Kiosk::Server::DeviceVerification.approve(user_code: user_code, user_id: user_id)
          [200, { "content-type" => "application/json" },
           [JSON.generate(ok: true, status: "approved")]]
        when "deny"
          Kiosk::Server::DeviceVerification.deny(user_code: user_code)
          [200, { "content-type" => "application/json" },
           [JSON.generate(ok: true, status: "denied")]]
        else
          [400, { "content-type" => "application/json" },
           [JSON.generate(ok: false, error: "decision must be 'approve' or 'deny'")]]
        end
      rescue Kiosk::Server::DeviceVerification::CodeNotFoundError => e
        [404, { "content-type" => "application/json" },
         [JSON.generate(ok: false, error: e.message)]]
      rescue ArgumentError => e
        [400, { "content-type" => "application/json" },
         [JSON.generate(ok: false, error: e.message)]]
      end
    end

    # Generic verify endpoint — accepts decision=approve|deny.
    post "/kiosk/_test/device_authorization/verify", to: ->(env) {
      req = Rack::Request.new(env)
      handle_verification.call(
        req.params["decision"].to_s,
        req.params["user_code"].to_s,
        req.params["user_id"].to_s,
      )
    }

    # Back-compat alias: hard-codes decision=approve. Used by the
    # sub-slice-2 e2e assertions; remove once those migrate.
    post "/kiosk/_test/device_authorization/approve", to: ->(env) {
      req = Rack::Request.new(env)
      handle_verification.call(
        "approve",
        req.params["user_code"].to_s,
        req.params["user_id"].to_s,
      )
    }


  end
end
