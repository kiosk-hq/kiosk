# frozen_string_literal: true

require "json"

Rails.application.routes.draw do
  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  root "home#index"

  # Unauthenticated agent bootstrap: protocol handshake + live surface, so an
  # agent that lands from the homepage can self-onboard with no prior knowledge.
  # (Demo: app-level; a follow-up moves this into kiosk-server as a convention.)
  get "/kiosk/help", to: "kiosk_help#show"

  # Kiosk wire surface (controllers shipped by kiosk-server).
  # In a follow-up release these will be mounted via the engine's own
  # routes drawer; for v0.1 alpha we wire them manually here.
  post "/kiosk/exec",                              to: "kiosk/server/exec#exec"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
  post "/kiosk/agents/register",                   to: "kiosk/server/agents_registration#create"

  # /.well-known/kiosk.json discovery endpoint — built on the fly from
  # Kiosk.configuration. Inlined here since kiosk-server doesn't yet
  # ship a controller for it.
  # well-known = the machine-readable HANDSHAKE: who/where/which version + issuer
  # (the AP2 `iss` anchor) + auth, served at the guessable conventional URL. It
  # is NOT the surface — it points to /kiosk/help, which carries the protocol +
  # the live queries/actions. The `verbs` summary is DERIVED from the actually
  # implemented verbs (no hardcoded capability list), the same source /kiosk/help
  # renders from, so the two never drift.
  get "/.well-known/kiosk.json", to: ->(env) {
    base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
    doc      = Kiosk::Server::WellKnown.build(base_url: base_url)
    endpoint = doc[:kiosk][:endpoint]
    doc[:kiosk].delete(:capabilities)          # drop the static capability list
    doc[:kiosk][:verbs] = Kiosk::Server::Executor::IMPLEMENTED_VERBS  # the truth
    doc[:kiosk][:help]  = "#{endpoint}/help"   # the surface + protocol live here
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
