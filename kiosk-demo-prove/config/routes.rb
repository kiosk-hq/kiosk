# frozen_string_literal: true

Rails.application.routes.draw do
  # Public root: what prove.my is (an anonymizing KYC broker) + the privacy
  # thesis. Rendered HTML — this app keeps the full middleware stack.
  root "home#index"

  # ── INTAKE (operator → broker, server-to-server) ─────────────────────────
  # An operator (skooti) starts a verification here. Authenticated by a shared
  # bearer secret + a pre-registered operator/callback allow-list (no arbitrary
  # callback_url is honoured — SSRF/open-relay guard). Returns a verification_url
  # carrying the unguessable 256-bit request_id.
  post "/verifications", to: "verifications#create"

  # ── VERIFICATION (broker → human) ────────────────────────────────────────
  # The human-facing yes/no page reached via the verification_url. The request
  # token in the URL is the ONLY credential (no sign-in — demo stub).
  get  "/verify", to: "verifications#show"
  post "/verify", to: "verifications#decide"

  # ── The broker's RSA public key (the "ProveKey" operators pin/trust) ─────
  # Operators fetch this once to configure c.kyc_public_key. A convenience for
  # the demo harness; production pins the key out-of-band.
  get  "/prove_key.pem", to: "verifications#public_key", defaults: { format: :text }
end
