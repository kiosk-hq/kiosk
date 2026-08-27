# Before and After — why AI assistants stall at Booking.com, and what hoteling proves

**Honesty note up front.** hoteling is what Booking.com *would* look like if it spoke Kiosk — a fake-but-realistic hotel-booking operator built to demonstrate the mechanism. Nothing below implies that real Booking.com works this way. The demo proves the *mechanism* works; whether operators will adopt it is an open question.

---

## Before — a real AI assistant on real Booking.com today

Every current personal AI assistant (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same wall: the connector stops at discovery.

**The Booking.com connector probed in-session confirms the end-state:**

> Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) **stop at discovery.** Their terminal step is a deep link back to the operator's own app/site, where the human must register and pay.

The Booking.com MCP connector exposes two tools: `accommodations_search` (returns property listings) and `answer_property_qa_by_ids` (answers natural-language questions about specific properties). The session schema's own `deeplink_id` field describes navigating *to* Booking.com — confirming the intended flow: **the AI assistant shows options, then deep-links the user out to Booking.com to register, authenticate, and pay.** There is no reserve, no checkout, no payment tool.

**The structural root cause is economic, not technical.** Booking.com's business model depends on an authenticated in-app session: display advertising, metasearch fees, loyalty points, and first-party data capture all require the human to complete the booking inside Booking.com's own funnel. A silent AI-assistant reservation via a structured API erases that session entirely. The discovery step *is* the product.

Anti-bot friction compounds this. Behavioral fingerprinting (Cloudflare Turnstile) flags AI-assistant traffic; the user's payment instrument lives outside the AI assistant's context; and EU/UK PSD2 SCA requires a biometric or device-OTP challenge on first use that only the human can satisfy.

**In short:** the AI assistant discovers available hotels, then hands back to the human. The human navigates to Booking.com, creates or logs into an account, passes bot checks, authenticates, and pays. The AI assistant's contribution is a glorified search result.

---

## With Kiosk — hoteling (`rake demo` output)

hoteling is a Rails 8.1 app that speaks Kiosk. Below is the output of
`bundle exec rake demo` — recorded **2026-08-26**, stdout and stderr as a
terminal shows them. `rake demo` is `demo:setup` then `demo:book`; the block
starts at `demo:book`'s FIRST line, so everything cut is `demo:setup`'s
`db:drop`/`db:create`/`db:schema:load`/`db:seed` chatter and nothing else.
From there down it is unedited, all three runs, last line to last line. The
identifiers are that run's; the dates are `Date.today + 30` / `+ 33`, so they
move with the day it is run.

<!-- derived: transcript | task: bundle exec rake demo | from: lib/tasks/demo.rake, script/hoteling_flow.rb, script/equihash_register.rb, script/pay_window.rb, config/environments/development.rb | keys_from: app/controllers/kiosk/hotels_controller.rb, app/controllers/kiosk/reservations_controller.rb | abridged: demo:setup's db:drop/db:create/db:schema:load/db:seed chatter, above the first line quoted -->
```
  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)

══ RUN 1: Happy path ══
  Server up at http://127.0.0.1:3003
  Registered: user_id=df4e6810-404d-4339-87e0-9e4eeef7ee8c
  Properties: 100 found, using property_id=27 (Amber Fatih Residence)
  Availability: 2 room type(s) available, using room_type_id=63 (Standard, €70.00/night)
  Reserved: booking_id=c811c2ee-3ad7-43f8-a89c-4ed8c216d4e0 total=€210.00
  Payment settled: settlement_id=8a806257-f1a0-48a1-b564-1f8ce64482b9
{"http_register":201,"http_properties":200,"http_availability":200,"http_reserve_room":200,"http_pay":200,"http_confirm_booking":200,"user_id":"df4e6810-404d-4339-87e0-9e4eeef7ee8c","agent_id":"bf31d135-b5da-4b37-9502-9aef561a9ecf","booking_id":"c811c2ee-3ad7-43f8-a89c-4ed8c216d4e0","total_cents":21000,"confirm_status":"confirmed","confirmation_code":"82ccc775-9c2e-4615-aec2-8d8aa5a47f9b","http_my_bookings":200,"stored_confirmation_code":"82ccc775-9c2e-4615-aec2-8d8aa5a47f9b"}
  OK  http_register == 201
  OK  http_properties == 200
  OK  http_availability == 200
  OK  http_reserve_room == 200
  OK  http_pay == 200
  OK  http_confirm_booking == 200
  OK  confirm_status == confirmed
  OK  booking_id present (c811c2ee-3ad7-43f8-a89c-4ed8c216d4e0)
  OK  confirmation_code round-trips through my_bookings (82ccc775-9c2e-4615-aec2-8d8aa5a47f9b)
  OK  bookings.confirmation_code == the code returned (82ccc775-9c2e-4615-aec2-8d8aa5a47f9b)
  OK  this run's booking is confirmed in the DB (id=c811c2ee-3ad7-43f8-a89c-4ed8c216d4e0)
  OK  exactly one kiosk.settlements row for this run's principal (df4e6810-404d-4339-87e0-9e4eeef7ee8c)
  OK  exactly one kiosk.reservations row for THIS booking (c811c2ee-3ad7-43f8-a89c-4ed8c216d4e0)
  Server stopped.

══ RUN 2: Server-gate negative — SKIP_PAY → 403 ══
  Server up at http://127.0.0.1:3003
  Registered: user_id=7647e7ad-d6f7-4319-ab68-5919e6c6a902
  Properties: 100 found, using property_id=27 (Amber Fatih Residence)
  Availability: 1 room type(s) available, using room_type_id=64 (Deluxe, €105.00/night)
  Reserved: booking_id=45d550b8-d039-4c29-b94a-1bdce850af3f total=€315.00
{"http_register":201,"http_properties":200,"http_availability":200,"http_reserve_room":200,"http_pay":null,"http_confirm_booking":403,"user_id":"7647e7ad-d6f7-4319-ab68-5919e6c6a902","agent_id":"690f3473-fdd8-44a1-b4d4-c435fe85f2ac","booking_id":"45d550b8-d039-4c29-b94a-1bdce850af3f","total_cents":31500,"confirm_status":null,"confirmation_code":null,"http_my_bookings":200,"stored_confirmation_code":null}
  OK  SKIP_PAY: http_confirm_booking == 403
  Server stopped.

══ RUN 3: capture-anchored paid state (K-853) ══
[kiosk] WARNING: generated an EPHEMERAL signing key (development); set KIOSK_SIGNING_KEY_B64/PEM for a stable key.

== (a) POSITIVE CONTROL: a booking nobody paid for reads `unpaid` ==
  OK    an untouched booking publishes payment_state=unpaid — the one answer that makes a fresh chain correct
  OK    confirm_booking on it refuses with the flat «no settlement» — correct HERE, because nothing was ever charged (got "no settlement for this booking")

== (b) IN FLIGHT: capture started, outcome unknown ==
  OK    the pay CLAIMED the booking (payment_status → paying) before the capture
  OK    no settlement row exists for it — the capture has not returned
  OK    my_bookings publishes payment_state=pending while the capture is outstanding (got "pending")
  OK    my_bookings does NOT publish `unpaid` for a booking whose capture may already have taken the money
  OK    confirm_booking names the outstanding capture instead of answering «no settlement» ("a payment for this booking is in progress and its outcome is not yet known — re-read my_bookings and confirm once its pa")
  OK    confirm_booking does NOT answer «no settlement for this booking» about an in-flight charge

== (c) PHASE-3 WINDOW: capture RETURNED, settlement row not yet written ==
  OK    still no settlement row — the engine's phase 3 has not run (this IS the window)
  OK    the cashier flipped the booking to `paid` the instant the capture returned
  OK    my_bookings publishes payment_state=paid on the CAPTURE alone, with zero settlement rows (got "paid")
  OK    confirm_booking succeeds on the capture-anchored witness alone, no settlement row required

== (d) AT MOST ONCE: N racing /pay for one booking ==
  OK    exactly ONE of 4 racing pays reached the PSP (got 1)
  OK    exactly ONE caller was told it captured; the other 3 were refused before any charge
  OK    the raced booking ends `paid`, once

== (e) TRANSCRIPT: `unpaid` was published only for the never-charged booking ==
  OK    booking 6200f4cb-8d01-430a-8514-48c09aa1cbbc never read `unpaid` after a capture was claimed for it (saw ["unpaid"])
  OK    booking ea81f21c-47c0-461b-9564-c4347d57efb3 never read `unpaid` after a capture was claimed for it (saw ["pending", "paid"])
  OK    booking 1ee47e3b-945f-4206-b070-851ec66754d8 never read `unpaid` after a capture was claimed for it (saw ["paid"])

  All capture-window assertions PASSED.

── Assertions ──
  All assertions passed.
```

`rake demo` runs **three** beats on purpose, and each one earns the next. RUN 2
skips the payment and asks for the same confirmation: the server refuses it
`403`, which is what makes RUN 1's `200` mean something. Run 1 took the first
room type; Run 2 sees one fewer, because Run 1's booking is holding it. RUN 3
boots no server at all — it drives the same verbs in-process
(`script/pay_window.rb`, via `rails runner`) because the thing under test is the
window BETWEEN a PSP capture and the settlement row that records it, and neither
half of that window can be held open over HTTP. It is the regression that keeps
a booking whose charge is in flight from publishing itself `unpaid` (K-853,
protocol.md §11.6). The stray `[kiosk] WARNING` line is that `rails runner`
booting a development process with an ephemeral signing key; it is in the block
because it is in the output.

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the hoteling issuer and surface.
2. **Self-register, and pay the toll** — generated an RSA-2048 keypair, then completed the proof-of-possession handshake: `GET /kiosk/auth/challenge?public_key=<urlencoded pem>` (the query parameter is REQUIRED — without it the endpoint answers `400 missing public_key query parameter`) → signed the challenge as an RS256 JWS (`aud` = the hoteling issuer) → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`. **That first POST comes back `402`**: registration here is uniformly tolled (`c.registration_pow_count = 1`, `config/initializers/kiosk.rb`), and the 402 is an RFC 9457 problem document carrying a top-level `challenges` array the SERVER minted — so nothing can be solved in advance. The client solves each challenge and re-POSTs the SAME signed body with the proof in the `Kiosk-PoW` header → HTTP 201 → `agent_id`, `user_id`, `access_token`. The transcript shows only the `201`, because `http_register` is what the driver reports for the second POST. No existing account. No human login. No bot check.
3. **Browse** — `GET /kiosk/properties` returned 100 hotel properties as a bare JSON array (name-ordered; the flow uses the first, Amber Fatih Residence, `property_id=27`). `GET /kiosk/availability?property_id=27&check_in=2026-09-25&check_out=2026-09-28` returned the room types still free for those nights, with nightly prices (price-ordered; the flow uses the first, Standard at €70.00/night).
4. **Reserve** — `POST /kiosk/reserve_room {property_id:27, room_type_id:63, check_in:"2026-09-25", check_out:"2026-09-28"}` → HTTP 200, and the body IS the result: `booking_id:"c811c2ee-…"` and `total_cents:21000` (3 nights × 7000), plus the quote the cart must be signed against (`currency`, `nights`, `nightly_price_cents`) and a `pay_hint`. A hold row was created in `kiosk.reservations`, stamped with a pay-by deadline.
5. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:21100`, `scope:"lodging"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:21000`, `line_items:[{sku:"Standard", qty:3, price_cents:7000, booking_id:"c811c2ee-…"}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws:…, cart_mandate_jws:…, payment_mandate_jws:…}` → HTTP 200 with `settlement_id`, `psp_reference`, `settled_amount_cents:21000` and `currency:"eur"`.
6. **Confirm** — `POST /kiosk/confirm_booking {booking_id:"c811c2ee-…"}` → HTTP 200, `status:"confirmed"`, `confirmation_code:"82ccc775-…"`. The server verified ownership (Gate 1) and the settled mandate referencing this booking (Gate 2) before confirming. The code is stored on the booking row — it is the reference the guest gives at the desk — and the run asserts it twice: `my_bookings` reports the same code, and so does the `bookings` row itself.

The database confirmed: one row in `bookings` with `status='confirmed'`, one row in `kiosk.settlements`, one row in `kiosk.reservations`.

The business outcome: the user said "book a hotel room for next month." Their assistant completed the full booking — discovery, registration, room selection, reservation, payment, confirmation — without the user touching anything and without the user having an account at hoteling beforehand.

The operator outcome: hoteling received a confirmed booking and a settled payment. The customer relationship stays with hoteling (the mandate carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator with a stub payment processor.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the operator adoption recipe

The delta between "today's Booking.com" and "hoteling" is an operator-side integration. The pieces:

**1. Add the Kiosk satellite gems**

<!-- derived: snippet | from: Gemfile | abridged: the kiosk gem lines and json_schemer only; the Rails/Postgres/dev-group lines around them are out -->
```ruby
# Gemfile
gem "kiosk-all",                path: "../kiosk-all"
gem "kiosk-core",               path: "../kiosk-core"
gem "kiosk-rls",                path: "../kiosk-rls"
gem "kiosk-server",             path: "../kiosk-server"
gem "kiosk-pow-equihash",       path: "../kiosk-pow-equihash"
gem "kiosk-reputation",         path: "../kiosk-reputation"
gem "kiosk-redteam",            path: "../kiosk-redteam"
gem "kiosk-user-idp-devise",    path: "../kiosk-user-idp-devise"

gem "json_schemer"
```

Those are this demo's own `Gemfile` lines, verbatim (the `path:` overrides are
the monorepo checkout; in production they are versioned RubyGems). Not all eight
are the minimum: `kiosk-core` + `kiosk-server` is the engine,
`kiosk-pow-equihash`/`kiosk-reputation` are what the registration toll and the
browse toll need, `kiosk-redteam` is the adversarial battery, `kiosk-rls` the
optional Postgres backstop, `kiosk-user-idp-devise` the human-session channel,
and `json_schemer` is required only because this origin turns
`c.validate_requests` on. The `kiosk-pay-stripe` adapter swaps in for real
payments; this demo does not carry it, and uses a stub PSP instead.

**2. Run the generator**

<!-- derived: none | why: the generator invocation an adopter types — a command, not output this repo produces -->
```
rails g kiosk:install
```

This emits exactly two things: `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the `kiosk.*` schema migrations — the namespace itself, the identity tables (`agents`, `agent_tokens`, `agent_mappings`), `reservations`, `device_authorizations`, the AP2 mandate trail (`intent_mandates`, `cart_mandates`, `payment_mandates`, `settlements`) and `kyc_attributes`, one row per anonymized attribute an attestation granted. Run `bin/rails db:migrate` to apply them.

The generator does **not** touch your routes. `kiosk-server` ships the wire
controllers; you mount them yourself. Below are the route statements this demo's
`config/routes.rb` actually draws, verbatim — every one of them, in file order.
Only that file's own comments are trimmed, plus the three lines that have
nothing to do with Kiosk (`devise_for`, `root`, and a telemetry route drawn only
under `KIOSK_TELEMETRY=1`).

<!-- derived: snippet | from: config/routes.rb | transform: dedent | abridged: the Kiosk wire lines only, quoted without the routes.draw indent; this demo's own devise/root/admin routes and every comment are out -->
```ruby
# config/routes.rb — the wire surface, hand-drawn.
get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"
get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
post "/kiosk/pay",                               to: "kiosk/server/wire#pay"
get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"

get "/agents.txt",                        to: "kiosk/server/discovery#agents_txt"
get "/agents.json",                       to: "kiosk/server/discovery#agents_json"
get "/.well-known/agent-configuration",   to: "kiosk/server/discovery#agent_configuration"
get "/.well-known/kiosk.json",            to: "kiosk/server/discovery#kiosk_json"
get "/.well-known/api-catalog",           to: "kiosk/server/discovery#api_catalog"
get "/kiosk/openapi.json",                to: "kiosk/server/open_api#show"

get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
```

Three things that table is worth reading for. **Every controller in it is
kiosk-server's** — including `/.well-known/kiosk.json`, which is
`Kiosk::Server::DiscoveryController#kiosk_json` rendering the same
`WellKnown.build_json` document; there is no Rack lambda to hand-write and no
part of the wire this operator implements. **The RESERVED lines come first and
the per-verb pair is drawn LAST**, so first-match protects `schema`, `pay` and
the auth plane from an operator verb that happens to share a name — and there is
no `/kiosk/query` and no `/kiosk/run`, because protocol 0.4 deleted the
multiplexed pair outright. **And none of this has to be hand-drawn at all:**
mounting the engine draws the whole table in one line — `kiosk-server`'s
`Engine` ships both the mount-prefixed drawer and the root-relative discovery
routes. hoteling writes them out by hand because that is the escape hatch the
engine documents, and because the expanded form shows an adopter exactly what
the mount installs.

**3. Declare the read verbs in a controller**

The verbs an assistant may call are ordinary Rails controller actions. Kiosk
ships a MIXIN, not a base class — which superclass a handler has is your
decision — and each class-level macro is claimed by the next `def`, so a method
with no macros above it is a helper the wire cannot see. `input_schema` and
`output_schema` are REQUIRED on every verb: a declaration missing either raises
as the class body is read, so the app does not boot.

**The snippet below is ABRIDGED, and every abridgement is marked where it
happens.** It was DERIVED from
`kiosk-demo-hoteling/app/controllers/kiosk/hotels_controller.rb` by deleting
text, never by rewriting it. Every line below is a line of that file with its
`description` cut out and nothing else altered — no rewording, no reordering,
nothing invented — and the two kinds of elision marker say so on their own
line. Three things were deleted. (1) Two of the five shipped queries,
`search_hotels` and `hotel_detail`. (2) Each remaining verb's prose
`description`, collapsed to a `description "…"   # elided` line, and every
`description:` key inside a schema. (3) The middle of `availability`'s body, at
an explicit marker. Everything else — field names, types, `required` lists,
`enum`s and the guards — is the shipped declaration.

<!-- derived: snippet | from: app/controllers/kiosk/hotels_controller.rb | transform: strip_descriptions | abridged: each verb's prose description, every schema description: key, and one verb's guards at a marked line -->
```ruby
# app/controllers/kiosk/hotels_controller.rb
class Kiosk::HotelsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # ── properties — the whole (small) catalogue of hotels, name-ordered.
  # ADR-0023: the `description` carries semantics only; fields live in the schema.
  kind :query
  description "…"   # elided — see the shipped file
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    property_id: { type: "integer" },
                    name:        { type: "string" },
                    city:        { type: "string" },
                  },
                  required: %w[property_id name city],
                }
  def properties
    # `pluck` rather than loading models: a projection, and naming the columns is
    # what keeps the wire's field names and their order a decision this handler
    # makes rather than a side effect of the schema.
    render json: Property.order(:name).pluck(:id, :name, :city).map { |id, name, city|
      { property_id: id, name: name, city: city }
    }
  end

  # ── availability — the OFFER: room types of one property with no live booking
  # overlapping the requested nights. `RoomType.free_for` is that predicate, and
  # `reserve_room` sells against the same scope, so the two cannot disagree (K-690).
  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer" },
                 check_in:    { type: "string", format: "date" },
                 check_out:   { type: "string", format: "date" },
               },
               required: ["property_id", "check_in", "check_out"]
  # The OFFER, not the catalogue. Empty means the property is sold out for those
  # nights and, since T-090, that is the ONLY thing empty means here — an unknown
  # `property_id` is 404.
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    room_type_id:        { type: "integer" },
                    name:                { type: "string" },
                    nightly_price_cents: { type: "integer" },
                    currency:            { type: "string" },
                  },
                  required: %w[room_type_id name nightly_price_cents currency],
                }
  def availability
    return unless kiosk_present?(params[:property_id], "property_id")
    return unless kiosk_present?(params[:check_in], "check_in")
    return unless kiosk_present?(params[:check_out], "check_out")

    property_id, refusal = WireArguments.integer(params[:property_id], field: "property_id",
                                                                       hint: WireArguments::HINT_PROPERTY_ID)
    return render_refusal(refusal) if refusal

    dates, refusal = WireArguments.stay_dates(params[:check_in], params[:check_out])
    return render_refusal(refusal) if refusal

    # ── GUARDS ELIDED HERE (this comment is the document's, not the file's) ──
    # Two more typed refusals follow in the shipped file, and both exist so that
    # an empty array keeps its ONE honest meaning: a `check_in` in the past is a
    # named 400 (`WireArguments.past_stay`), and a `property_id` nobody has is
    # 404 not_found (`WireArguments.existing_property`). Neither is answered
    # with `[]`, which here means only SOLD OUT. The method then ends with the
    # lines below, which ARE the shipped ones.
    check_in, check_out = dates
    # The currency is advertised on every row so an assistant knows to sign its
    # cart in EUR (the cashier rejects any other currency at capture).
    render json: RoomType.where(property_id: property_id)
                         .free_for(property_id, check_in, check_out)
                         .order(:nightly_price_cents)
                         .pluck(:id, :name, :nightly_price_cents)
                         .map { |id, name, cents|
                           { room_type_id: id, name: name, nightly_price_cents: cents, currency: "eur" }
                         }
  end

  # ── my_bookings — per-identity: the caller's OWN bookings only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable, and
  # `owned_by_current_principal` is the ONE place the identity predicate is
  # written (see Booking for why it stays SQL-side).
  #
  # THE RECONCILIATION SURFACE (K-853): this is the "per-user query" protocol.md
  # §11.6 sends an assistant to after a `pay` whose response it never read, so
  # what it publishes about money is normative. `payment_state` is a TRI-state on
  # purpose — §11.6 requires a third answer distinct from paid and not-paid,
  # because "no record" is not evidence that no money moved.
  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    booking_id:        { type: "string" },
                    property_id:       { type: "integer" },
                    room_type_id:      { type: "integer" },
                    check_in:          { type: "string" },
                    check_out:         { type: "string" },
                    total_cents:       { type: "integer" },
                    status:            { type: "string" },
                    payment_state:     { type: "string", enum: %w[unpaid pending paid] },
                    confirmation_code: { type: %w[string null] },
                  },
                  required: %w[booking_id property_id room_type_id check_in check_out
                               total_cents status payment_state confirmation_code],
                }
  def my_bookings
    # The settled flag is a CORRELATED EXISTS over the CALLER's settlements — one
    # statement for the whole list, not one query per row — and it is only the
    # second of the two witnesses {Booking.payment_state} weighs.
    settled_flag = Booking.settled_flag(Settlement.of_current_principal)
    render json: Booking.owned_by_current_principal
                        .order(created_at: :desc)
                        .pluck(:id, :property_id, :room_type_id, :check_in, :check_out,
                               :total_cents, :status, :payment_status, settled_flag,
                               :confirmation_code)
                        .map { |id, property_id, room_type_id, check_in, check_out,
                                total_cents, status, payment_status, settled, confirmation_code|
                          { booking_id:        id,
                            property_id:       property_id,
                            room_type_id:      room_type_id,
                            check_in:          check_in,
                            check_out:         check_out,
                            total_cents:       total_cents,
                            status:            status,
                            payment_state:     Booking.payment_state(payment_status, settled),
                            confirmation_code: confirmation_code }
                        }
  end
end
```

A handler sees only assistant-supplied params and runs inside a session whose
`kiosk.current_user_id()` is the authenticated principal. `my_bookings` scopes
by that server-derived UUID — an assistant cannot inject a different `user_id`
to read another principal's bookings.

**4. Declare the write verbs next door (`reserve_room`, `confirm_booking`)**

The kind of verb is a property of each DECLARATION (`kind :action` below), not
of the class, so one controller could carry all eight. Two is this demo's shape,
not a rule.

Derived from
`kiosk-demo-hoteling/app/controllers/kiosk/reservations_controller.rb` the same
way as the read snippet: every line is that file's with its `description` cut
out and nothing else altered, and the two `description "…"   # elided` markers
say so. One of hoteling's three
shipped actions, `payment_setup`, is left out; the other two are here whole,
bodies included.

<!-- derived: snippet | from: app/controllers/kiosk/reservations_controller.rb | transform: strip_descriptions | abridged: both verbs' prose descriptions and every schema description: key -->
```ruby
# app/controllers/kiosk/reservations_controller.rb
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # reserve_room — the hold. See {ReserveRoomOperation} for the inventory guard;
  # the two identity values below are read from the identity the wire resolved
  # rather than from arguments, which is what makes a forged `user_id` in the
  # body inert. The descriptor deliberately does NOT promise the hold expires on
  # its own: the deadline is recorded and no sweep enforces it (K-936).
  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id:  { type: "integer" },
                 room_type_id: { type: "integer" },
                 check_in:     { type: "string", format: "date" },
                 check_out:    { type: "string", format: "date" },
               },
               required: ["property_id", "room_type_id", "check_in", "check_out"]
  output_schema type: "object",
                additionalProperties: false,
                properties: {
                  booking_id:          { type: "string" },
                  total_cents:         { type: "integer" },
                  currency:            { type: "string" },
                  nights:              { type: "integer" },
                  nightly_price_cents: { type: "integer" },
                  pay_hint:            { type: "string" },
                },
                required: %w[booking_id total_cents currency nights nightly_price_cents pay_hint]
  def reserve_room
    render_operation ReserveRoomOperation.call(
      principal_id: kiosk_identity.user_id,
      agent_id:     kiosk_identity.agent_id,
      property_id:  params[:property_id],
      room_type_id: params[:room_type_id],
      check_in:     params[:check_in],
      check_out:    params[:check_out],
    )
  end

  # confirm_booking — the two gates and the durable confirmation code. See
  # {ConfirmBookingOperation}; the principal is NOT passed in, because both gates
  # express it as a WHERE predicate over `kiosk.current_user_id()`.
  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid" },
               },
               required: ["booking_id"]
  output_schema type: "object",
                additionalProperties: false,
                properties: {
                  booking_id:        { type: "string" },
                  status:            { const: "confirmed" },
                  confirmation_code: { type: "string" },
                },
                required: %w[booking_id status confirmation_code]
  def confirm_booking
    render_operation ConfirmBookingOperation.call(booking_id: params[:booking_id])
  end
end
```

Both handlers are four lines because the work is in `app/operations/`, so a
console or a rake task can reuse it. `reserve_room`'s INSERT, its
`kiosk.reservations` hold row and its inventory guard live in
`ReserveRoomOperation`; the two identity values come from the identity the WIRE
resolved, never from arguments, which is what makes a forged `user_id` in the
body inert. `ConfirmBookingOperation` runs both gates inside one transaction:

- **Gate 1 — ownership.** `booking.user_id` must equal `kiosk.current_user_id()`
  and the booking must still be `reserved`.
- **Gate 2 — payment, as a DISJUNCTION of two witnesses.** Either the booking's
  own row says this principal already paid for it (`payment_status = 'paid'` AND
  `paid_by_user_id = kiosk.current_user_id()`), or a settled mandate of this
  principal's carries a cart whose `line_items` reference this `booking_id`. The
  first arm exists because a PSP capture returns BEFORE the settlement row is
  written, and in that window it is the only witness there is — which is exactly
  what RUN 3 of the transcript above holds open and asserts. A booking whose
  capture is still outstanding satisfies neither arm and is refused by NAME
  («a payment for this booking is in progress…»), never as «no settlement».

Neither gate takes the principal as an argument: both express it as a WHERE
predicate over `kiosk.current_user_id()`, so it is un-forgeable without being
named in Ruby at all. A refusal is Rails' idiom, not a Kiosk class —
`render_operation` turns a refused result into `render json: { error: { code:
"forbidden", … } }, status: :forbidden`, and the wire turns that into an RFC
9457 problem document whose top-level `code` is the token an assistant branches
on.

**5. Name the controllers in the initializer**

<!-- derived: snippet | from: config/initializers/kiosk.rb | abridged: the handler-naming lines only, out of the Kiosk.configure block -->
```ruby
Kiosk.configure do |c|
  c.handlers = %w[Kiosk::HotelsController Kiosk::ReservationsController]
end
```

This line is load-bearing. The wire reaches a handler through the registry and
nothing else in the app references these classes, so in development — where
Rails does not eager-load `app/` — an origin that names none of them serves no
verbs at all. There is no second way in: `Kiosk::Server::Queries.register`, the block API
the 0.3 series shipped, was removed in 0.4 and now raises NoMethodError.

**6. Wire a payment-provider adapter**

These are the two lines this demo's own `config/initializers/kiosk.rb` carries,
verbatim (they sit inside its `Kiosk.configure do |c|` block, ~60 lines apart):

<!-- derived: snippet | from: config/initializers/kiosk.rb | abridged: the issuer and payment-provider lines only, ~60 lines apart in the Kiosk.configure block -->
```ruby
# config/initializers/kiosk.rb
  c.issuer = Rails.configuration.x.kiosk.issuer

  c.payment_provider = ValidatingBookingProvider.new(StubPsp.new, currency: "eur")
```

The issuer is read from `Rails.configuration`, not written here, so the posture
lives in `config/environments/*` — required in production, localhost default in
dev and test. The provider is a stub PSP (`StubPsp`, a
`Kiosk::PaymentProviders::Base` subclass) wrapped in this demo's own cashier
check: `ValidatingBookingProvider` verifies the agent-signed cart against the
operator's own quote — currency EUR, a single booking reference, and the total
hoteling quoted for that booking — BEFORE anything is captured. Swapping in real
payments is one line and touches no other code:

<!-- derived: none | why: an illustrative one-line swap — no file in this repo carries it, and the prose beside it says so -->
```ruby
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(api_key: ENV["STRIPE_SECRET_KEY"])
```

That is what getgrocery does; hoteling stays on the stub so its transcript
charges nothing.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or a migration on any table you already own. The satellite gems add a parallel surface in their own `kiosk.*` schema; your tables keep their columns and your human-facing app keeps working unchanged.

What it DOES touch, and this demo is honest about it because an adopter will hit it on day one: a handful of additions to `app/models/booking.rb`, an operator model. `owned_by_current_principal` is the `kiosk.current_user_id()` scope every owner-scoped read goes through, written once so the app-layer check and the optional RLS policy are the same expression; `settled_flag` and `payment_state` are what turn two witnesses into the tri-state `my_bookings` publishes. None of them changes the schema, and all of them are the sort of thing you would write anyway to expose a model over any API.

**What this enables:** any personal AI assistant that has read the published Kiosk skill — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a hotel booking without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic; the anti-bot wall stays in place for everything else.

---

*Validation research: primary evidence from live connector probes (Booking.com) as of 2026-06-22. The Booking.com connector finding (search + QA only, no reserve/checkout tool) was confirmed in-session via MCP tool introspection.*
