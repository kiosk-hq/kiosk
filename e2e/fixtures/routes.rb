# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise) — the web session the account-binding surfaces
  # authenticate through kiosk-user-idp-devise. claim_flow.rb drives this very
  # form; there is no stub session channel to assert instead.
  devise_for :users

  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # ── the responses RAILS composes, not Kiosk ──────────────────────────────
  #
  # §3.6 binds every response under the mount "on success and on error alike",
  # and the two hardest to bind are the two no Kiosk code ever composes: a
  # routing 404 for a path under the mount that nobody drew, and an unhandled
  # 500. `GET /kiosk/nope/nope` is the 404 probe: nothing under the mount draws
  # it, so it matches no route and Rails composes the answer.
  # `/kiosk/boom` is the 500, and the two `/operator/*` lines are its
  # blast-radius control: the SAME exception path outside the mount must carry
  # none of the three headers, because the engine is installed in somebody
  # else's application and does not speak for its routes.
  #
  # Rack endpoints rather than controllers: there is nothing to hold in a
  # class, and a fixture controller that only raises would have to be copied
  # and declared like every other hand-written file.
  get "/kiosk/boom",      to: ->(_env) { raise "e2e: a deliberate unhandled 500 under the mount" }
  get "/operator/health", to: ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] }
  get "/operator/boom",   to: ->(_env) { raise "e2e: a deliberate unhandled 500 OUTSIDE the mount" }
end
