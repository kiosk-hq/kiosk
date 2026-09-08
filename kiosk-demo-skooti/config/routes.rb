# frozen_string_literal: true

Rails.application.routes.draw do

  # Human sign-in (Devise) — the web session that approves assistant links.
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller — instead of a
  # bodyless 401; every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Public root page: what this demo is + live DOMAIN activity (fleet + rental
  # counts read from skooti's own tables) + how an agent pokes the wire. The app
  # carries the full middleware stack (Devise sessions), and HomeController
  # inherits ApplicationController so HTML renders.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # KYC broker callback — the broker → operator leg. `run
  # request_kyc` calls the broker's intake with THIS callback; on the human's
  # approve, the broker POSTs the signed anonymized {age_over_18, licence_a}
  # claim here. skooti verifies it against the trusted ProveKey, checks the
  # nonce/operator/request_id it stored, and parks the jws for the agent to
  # fetch via kyc_status and submit to /kiosk/agents/kyc. The self-hosted stub
  # KYC-provider page (/kyc/verify) is RETIRED — the broker now owns issuance.
  post "/kyc/callback",                            to: "kyc_callback#create"
end
