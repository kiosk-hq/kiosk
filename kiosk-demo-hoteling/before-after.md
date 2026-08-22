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

hoteling is a Rails 8.1 app that speaks Kiosk. Below is the **verbatim** output
of `rake demo` — recorded **2026-08-20** against a booted demo, `demo:setup`'s
database chatter removed and nothing else touched. The identifiers are that
run's; the dates are `Date.today + 30` / `+ 33`, so they move with the day it is
run.

```
  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)

══ RUN 1: Happy path ══
  Server up at http://127.0.0.1:3003
  Registered: user_id=16f146b9-eec8-4f85-871f-29845c94d6dc
  Properties: 100 found, using property_id=27 (Amber Fatih Residence)
  Availability: 2 room type(s) available, using room_type_id=63 (Standard, €70.00/night)
  Reserved: booking_id=dab8db12-40fe-42ee-bf93-8144e983772d total=€210.00
  Payment settled: settlement_id=b42373ab-204a-4bdf-a0a0-16500f87608f
{"http_register":201,"http_properties":200,"http_availability":200,"http_reserve_room":200,"http_pay":200,"http_confirm_booking":200,"user_id":"16f146b9-eec8-4f85-871f-29845c94d6dc","agent_id":"069556e1-0d27-4d98-9581-3a5fc3fc566e","booking_id":"dab8db12-40fe-42ee-bf93-8144e983772d","total_cents":21000,"confirm_status":"confirmed","confirmation_code":"d8109a3e-29b9-46d7-b4fc-7a69ce19f786","http_my_bookings":200,"stored_confirmation_code":"d8109a3e-29b9-46d7-b4fc-7a69ce19f786"}
  OK  http_register == 201
  OK  http_properties == 200
  OK  http_availability == 200
  OK  http_reserve_room == 200
  OK  http_pay == 200
  OK  http_confirm_booking == 200
  OK  confirm_status == confirmed
  OK  booking_id present (dab8db12-40fe-42ee-bf93-8144e983772d)
  OK  confirmation_code round-trips through my_bookings (d8109a3e-29b9-46d7-b4fc-7a69ce19f786)
  OK  bookings.confirmation_code == the code returned (d8109a3e-29b9-46d7-b4fc-7a69ce19f786)
  OK  bookings[status=confirmed] >= 1 (got 1)
  OK  kiosk.settlements >= 1 (got 1)
  OK  kiosk.reservations[resource_kind=room_booking] >= 1 (got 1)
  Server stopped.

══ RUN 2: Server-gate negative — SKIP_PAY → 403 ══
  Server up at http://127.0.0.1:3003
  Registered: user_id=4433c5b7-75d8-41f0-8456-0262cce99970
  Properties: 100 found, using property_id=27 (Amber Fatih Residence)
  Availability: 1 room type(s) available, using room_type_id=64 (Deluxe, €105.00/night)
  Reserved: booking_id=000b17d2-e21a-44d1-ac13-935e4932591c total=€315.00
{"http_register":201,"http_properties":200,"http_availability":200,"http_reserve_room":200,"http_pay":null,"http_confirm_booking":403,"user_id":"4433c5b7-75d8-41f0-8456-0262cce99970","agent_id":"4d67ad53-42e8-4a26-bf72-2404b89a0db7","booking_id":"000b17d2-e21a-44d1-ac13-935e4932591c","total_cents":31500,"confirm_status":null,"confirmation_code":null,"http_my_bookings":200,"stored_confirmation_code":null}
  OK  SKIP_PAY: http_confirm_booking == 403
  Server stopped.

── Assertions ──
  All assertions passed.
```

`rake demo` runs the flow twice on purpose. RUN 2 skips the payment and asks for
the same confirmation: the server refuses it `403`, which is what makes RUN 1's
`200` mean something. Run 1 took the first room type; Run 2 sees one fewer,
because Run 1's booking is holding it.

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the hoteling issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, then completed the proof-of-possession handshake: `GET /kiosk/auth/challenge` → signed the challenge as an RS256 JWS (`aud` = the hoteling issuer) → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}` → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No bot check.
3. **Browse** — `GET /kiosk/properties` returned 100 hotel properties as a bare JSON array (name-ordered; the flow uses the first, Amber Fatih Residence, `property_id=27`). `GET /kiosk/availability?property_id=27&check_in=2026-09-19&check_out=2026-09-22` returned the room types still free for those nights, with nightly prices (price-ordered; the flow uses the first, Standard at €70.00/night).
4. **Reserve** — `POST /kiosk/reserve_room {property_id:27, room_type_id:63, check_in:"2026-09-19", check_out:"2026-09-22"}` → HTTP 200, and the body IS the result: `booking_id:"dab8db12-…"` and `total_cents:21000` (3 nights × 7000), plus the quote the cart must be signed against (`currency`, `nights`, `nightly_price_cents`) and a `pay_hint`. A hold row was created in `kiosk.reservations`, stamped with a pay-by deadline.
5. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:21100`, `scope:"lodging"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:21000`, `line_items:[{sku:"Standard", qty:3, price_cents:7000, booking_id:"dab8db12-…"}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws:…, cart_mandate_jws:…, payment_mandate_jws:…}` → HTTP 200 with `settlement_id`, `psp_reference`, `settled_amount_cents:21000` and `currency:"eur"`.
6. **Confirm** — `POST /kiosk/confirm_booking {booking_id:"dab8db12-…"}` → HTTP 200, `status:"confirmed"`, `confirmation_code:"d8109a3e-…"`. The server verified ownership (Gate 1) and the settled mandate referencing this booking (Gate 2) before confirming. The code is stored on the booking row — it is the reference the guest gives at the desk — and the run asserts it twice: `my_bookings` reports the same code, and so does the `bookings` row itself.

The database confirmed: one row in `bookings` with `status='confirmed'`, one row in `kiosk.settlements`, one row in `kiosk.reservations`.

The business outcome: the user said "book a hotel room for next month." Their assistant completed the full booking — discovery, registration, room selection, reservation, payment, confirmation — without the user touching anything and without the user having an account at hoteling beforehand.

The operator outcome: hoteling received a confirmed booking and a settled payment. The customer relationship stays with hoteling (the mandate carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator with a stub payment processor.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the operator adoption recipe

The delta between "today's Booking.com" and "hoteling" is an operator-side integration. The pieces:

**1. Add the Kiosk satellite gems**

```ruby
# Gemfile
gem "kiosk-core",   path: "../kiosk-core"
gem "kiosk-rls",    path: "../kiosk-rls"
gem "kiosk-server", path: "../kiosk-server"
```

In production these are versioned RubyGems. The `kiosk-pay-stripe` adapter swaps in for real payments (`gem "kiosk-pay-stripe"`).

**2. Run the generator**

```
rails g kiosk:install
```

This emits exactly two things: `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the `kiosk.*` schema migrations — the namespace itself, the identity tables (`agents`, `agent_tokens`, `agent_mappings`), `reservations`, `device_authorizations`, the AP2 mandate trail (`intent_mandates`, `cart_mandates`, `payment_mandates`, `settlements`) and `kyc_attributes`, one row per anonymized attribute an attestation granted. Run `bin/rails db:migrate` to apply them.

The generator does **not** touch your routes. `kiosk-server` ships the wire controllers; you mount them yourself. In this demo that block lives in `config/routes.rb`:

```ruby
# config/routes.rb — the wire surface, mounted manually.
# The RESERVED endpoints first, so first-match protects them.
get  "/kiosk/schema",         to: "kiosk/server/wire#schema"
post "/kiosk/pay",            to: "kiosk/server/wire#pay"
get  "/kiosk/auth/challenge", to: "kiosk/server/auth#challenge"
post "/kiosk/auth/register",  to: "kiosk/server/auth#register"
post "/kiosk/auth/login",     to: "kiosk/server/auth#login"
post "/kiosk/auth/revoke",    to: "kiosk/server/auth#revoke"

# Then, LAST, the per-verb pair: one endpoint per registered verb, resolved
# against the registry at request time. GET /kiosk/<query-name>,
# POST /kiosk/<action-name>. There is no /kiosk/query and no /kiosk/run —
# protocol 0.4 deleted the multiplexed pair outright.
get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }

# /.well-known/kiosk.json is built on the fly from Kiosk.configuration;
# kiosk-server does not yet ship a controller for it, so it is inlined here.
get "/.well-known/kiosk.json", to: ->(env) {
  base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
  [200, { "content-type" => "application/json" },
   [Kiosk::Server::WellKnown.build_json(base_url: base_url)]]
}
```

(A follow-up release will mount these via the engine's own routes drawer so this block collapses to one line.)

**3. Declare the read verbs in a controller**

The verbs an assistant may call are ordinary Rails controller actions. Kiosk
ships a MIXIN, not a base class — which superclass a handler has is your
decision — and each class-level macro is claimed by the next `def`, so a method
with no macros above it is a helper the wire cannot see. `input_schema` and
`output_schema` are REQUIRED on every verb: a declaration missing either raises
as the class body is read, so the app does not boot.

**The snippet below is ABRIDGED, not invented:** it is three of hoteling's five
shipped queries (`search_hotels` and `hotel_detail` are left out), with each
verb's full prose `description` and its per-property `description` lines elided
and the argument guards left to the shipped file. Every field name, type and
`required` list is the shipped one verbatim — read
`kiosk-demo-hoteling/app/controllers/kiosk/hotels_controller.rb` for the whole
thing.

```ruby
# app/controllers/kiosk/hotels_controller.rb
class Kiosk::HotelsController < ActionController::API
  include Kiosk::Handler

  kind :query
  description "Browse the whole hotel catalogue this origin serves. It is small, so " \
              "it comes back entire rather than a page at a time. Once the human " \
              "narrows to one, `availability` says which of its room types are still " \
              "free for the nights they want and `reserve_room` takes the hold."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { property_id: { type: "integer" },
                                name:        { type: "string" },
                                city:        { type: "string" } },
                  required: %w[property_id name city],
                }
  def properties
    # `id` becomes `property_id` on the wire: a summary row's id field carries
    # the SAME name as the param the next verb takes, so the assistant copies
    # the key straight through instead of guessing they are the same thing.
    render json: Property.order(:name).pluck(:id, :name, :city)
                         .map { |id, name, city| { property_id: id, name:, city: } }
  end

  kind :query
  description "Check which room types are still free at ONE hotel for ONE stay. An " \
              "EMPTY array means that hotel is SOLD OUT for those nights, not that it " \
              "has no rooms. Once the human picks a room type, `reserve_room` holds it."
  input_schema type: "object", additionalProperties: false,
               required: %w[property_id check_in check_out],
               properties: {
                 property_id: { type: "integer" },
                 check_in:    { type: "string", format: "date" },
                 check_out:   { type: "string", format: "date" },
               }
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { room_type_id:        { type: "integer" },
                                name:                { type: "string" },
                                nightly_price_cents: { type: "integer" },
                                currency:            { type: "string" } },
                  required: %w[room_type_id name nightly_price_cents currency],
                }
  def availability
    # `free_for` is the availability predicate, and `reserve_room` sells against
    # the same scope, so the offer and the sale cannot disagree. `currency` rides
    # on every row so an assistant knows to sign its cart in EUR.
    render json: RoomType.where(property_id: params[:property_id])
                         .free_for(params[:property_id], params[:check_in], params[:check_out])
                         .order(:nightly_price_cents)
                         .pluck(:id, :name, :nightly_price_cents)
                         .map { |id, name, cents|
                           { room_type_id: id, name:, nightly_price_cents: cents, currency: "eur" }
                         }
  end

  kind :query
  description "List this principal's hotel bookings (scoped to authenticated user). " \
              "This is the query to re-read after a payment whose response never " \
              "arrived: each row says where that booking stands with the hotel and " \
              "where its money stands, and a booking whose charge is still outstanding " \
              "says so rather than reporting itself unpaid."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { booking_id:        { type: "string" },
                                property_id:       { type: "integer" },
                                room_type_id:      { type: "integer" },
                                check_in:          { type: "string" },
                                check_out:         { type: "string" },
                                total_cents:       { type: "integer" },
                                status:            { type: "string" },
                                payment_state:     { type: "string", enum: %w[unpaid pending paid] },
                                confirmation_code: { type: %w[string null] } },
                  required: %w[booking_id property_id room_type_id check_in check_out
                               total_cents status payment_state confirmation_code],
                }
  def my_bookings
    settled_flag = Booking.settled_flag(Settlement.of_current_principal)
    render json: Booking.owned_by_current_principal
                        .order(created_at: :desc)
                        .pluck(:id, :property_id, :room_type_id, :check_in, :check_out,
                               :total_cents, :status, :payment_status, settled_flag,
                               :confirmation_code)
                        .map { |id, property_id, room_type_id, check_in, check_out,
                                total_cents, status, payment_status, settled, confirmation_code|
                          { booking_id: id, property_id:, room_type_id:, check_in:, check_out:,
                            total_cents:, status:,
                            payment_state: Booking.payment_state(payment_status, settled),
                            confirmation_code: }
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

Abridged the same way as the read snippet above: two of hoteling's three shipped
actions (`payment_setup` is left out), with the prose `description` and the
per-property `description` lines elided. Field names, types and `required` lists
are the shipped ones verbatim.

```ruby
# app/controllers/kiosk/reservations_controller.rb
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals   # the app's own concern: turns an Operation result into a render

  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object", additionalProperties: false,
               required: %w[property_id room_type_id check_in check_out],
               properties: {
                 property_id:  { type: "integer" },
                 room_type_id: { type: "integer" },
                 check_in:     { type: "string", format: "date" },
                 check_out:    { type: "string", format: "date" },
               }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id:          { type: "string" },
                              total_cents:         { type: "integer" },
                              currency:            { type: "string" },
                              nights:              { type: "integer" },
                              nightly_price_cents: { type: "integer" },
                              pay_hint:            { type: "string" } },
                required: %w[booking_id total_cents currency nights
                             nightly_price_cents pay_hint]
  def reserve_room
    # Four lines: read the arguments off the request, hand them to an Operation,
    # render what it answers. The INSERT + the kiosk.reservations hold row + the
    # inventory guard live in app/operations/, so a console or a rake task can
    # reuse them. The two identity values come from the identity the WIRE
    # resolved, never from arguments — which is what makes a forged `user_id`
    # in the body inert.
    render_operation ReserveRoomOperation.call(
      principal_id: kiosk_identity.user_id,
      agent_id:     kiosk_identity.agent_id,
      property_id:  params[:property_id],
      room_type_id: params[:room_type_id],
      check_in:     params[:check_in],
      check_out:    params[:check_out],
    )
  end

  kind :action
  description "Confirm a reserved booking (requires a payment mandate referencing this " \
              "booking). Returns the durable `confirmation_code` the hotel stores against " \
              "the booking — my_bookings lists the same code afterwards."
  input_schema  type: "object", additionalProperties: false,
                required: %w[booking_id],
                properties: { booking_id: { type: "string", format: "uuid" } }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id:        { type: "string" },
                              status:            { const: "confirmed" },
                              confirmation_code: { type: "string" } },
                required: %w[booking_id status confirmation_code]
  def confirm_booking
    # ConfirmBookingOperation runs both gates inside one transaction:
    #   Gate 1: ownership — booking.user_id must equal kiosk.current_user_id() AND status='reserved'
    #   Gate 2: payment  — a settled payment_mandate whose cart line_items @> [{booking_id:}]
    # The principal is not passed in: both gates express it as a WHERE predicate
    # over kiosk.current_user_id(), so it is un-forgeable without naming it in
    # Ruby at all. A refusal is Rails' idiom, not a Kiosk class — render_operation
    # turns a refused result into
    #   render json: { error: { code: "forbidden", … } }, status: :forbidden
    #   — and the wire turns that into an RFC 9457 problem document whose
    #     top-level `code` is the token an assistant branches on
    render_operation ConfirmBookingOperation.call(booking_id: params[:booking_id])
  end
end
```

**5. Name the controllers in the initializer**

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

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer           = "https://hoteling.demo.kiosk.tech"
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(api_key: ENV["STRIPE_SECRET_KEY"])
end
```

The stub PSP (`StubPsp`, a `Kiosk::PaymentProviders::Base` subclass) used in the demo can be swapped for the Stripe adapter without touching any other code.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the operator's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal AI assistant that has read the published Kiosk skill — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a hotel booking without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic; the anti-bot wall stays in place for everything else.

---

*Validation research: primary evidence from live connector probes (Booking.com) as of 2026-06-22. The Booking.com connector finding (search + QA only, no reserve/checkout tool) was confirmed in-session via MCP tool introspection.*
