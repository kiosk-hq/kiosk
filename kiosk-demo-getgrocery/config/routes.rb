# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise) — the web session that approves assistant links.
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller — instead of a
  # bodyless 401; every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # KYC broker callback — the broker → operator leg. `request_kyc` calls the
  # broker's intake with THIS callback; on the human's
  # approve, the broker POSTs the signed anonymized {age_over_18} claim here.
  # getgrocery verifies it against the trusted ProveKey, checks the
  # nonce/operator/request_id it stored, and parks the jws for the agent to
  # fetch via kyc_status and submit to /kiosk/agents/kyc.
  post "/kyc/callback",                            to: "kyc_callback#create"

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders

  # ─── Stripe Checkout return page ──────────────────────────────────────────
  # The SetupIntent success_url (return_url in the initializer) lands the human
  # here after they save a card. Without this route the human hit a 404
  # post-card-entry (a demo gap this route closes). Production providers point at
  # kiosk.tech/payment/return; a self-hosted demo serves its own.
  get "/payment/return", to: ->(_env) {
    [200, { "content-type" => "text/html; charset=utf-8" },
     ["<!DOCTYPE html><html><head><meta charset='utf-8'><title>Card saved</title></head>" \
      "<body style='font-family:system-ui,sans-serif;text-align:center;padding:64px'>" \
      "<h1>Card saved ✓</h1><p>Your assistant can now pay on your behalf. " \
      "You can close this tab.</p>" \
      "<p style='color:#888;font-size:14px'>getgrocery · Stripe test mode</p>" \
      "</body></html>"]]
  }
end
