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

hoteling is a Rails 8.1 app that speaks Kiosk. The following is the recorded output of `rake demo`.

```
  Registered: user_id=<uuid>
  Properties: 5 found, using id=4 (Bosphorus Palace)
  Availability: 2 room type(s) available, using id=<id> (Classic, 15000c/night)
  Reserved: booking_id=<uuid> total=45000c
  Payment settled: settlement_id=<uuid>

── Assertions ──
  OK  http_register == 201
  OK  http_properties == 200
  OK  http_availability == 200
  OK  http_reserve_room == 200
  OK  http_pay == 200
  OK  http_confirm_booking == 200
  OK  confirm_status == confirmed
  OK  booking_id present (<uuid>)
  OK  bookings[status=confirmed] >= 1 (got 1)
  OK  kiosk.settlements >= 1 (got 1)
  OK  kiosk.reservations[resource_kind=room_booking] >= 1 (got 1)

  All assertions passed.
```

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the hoteling issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, then completed the proof-of-possession handshake: `GET /kiosk/auth/challenge` → signed the challenge as an RS256 JWS (`aud` = the hoteling issuer) → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}` → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No bot check.
3. **Browse** — `GET /kiosk/properties` returned 5 hotel properties as a bare JSON array (ordered by name; the flow uses the first, Bosphorus Palace, id=4). `GET /kiosk/availability?property_id=4&check_in=2026-07-28&check_out=2026-07-31` returned available room types with nightly prices (ordered by price; the flow uses the first, Classic).
4. **Reserve** — `POST /kiosk/reserve_room {property_id:4, room_type_id:<id>, check_in:"2026-07-28", check_out:"2026-07-31"}` → HTTP 200, and the body IS the result: `booking_id:<uuid>`, `total_cents:45000`. A TTL hold was created in `kiosk.reservations`.
5. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:45100`, `scope:"lodging"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:45000`, `line_items:[{sku:"Classic", qty:3, booking_id:<uuid>}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws:…, cart_mandate_jws:…, payment_mandate_jws:…}` → `settled_amount_cents:45000`, `ok:true`.
6. **Confirm** — `POST /kiosk/confirm_booking {booking_id:<uuid>}` → HTTP 200, `status:"confirmed"`, `confirmation_code:<uuid>`. The server verified ownership (Gate 1) and the settled mandate referencing this booking (Gate 2) before confirming. The code is stored on the booking row — it is the reference the guest gives at the desk, and `my_bookings` reports the same one afterwards.

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

This emits exactly two things: `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the nine `kiosk.*` schema migrations (the namespace with agents, sessions, actions-log, reservations, device-authorizations, mandate tables, plus the KYC column). Run `bin/rails db:migrate` to apply them.

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

```ruby
# app/controllers/kiosk/hotels_controller.rb
class Kiosk::HotelsController < ActionController::API
  include Kiosk::Query

  description "Browse the hotels this operator takes bookings for."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { id:   { type: "integer" },
                                name: { type: "string" },
                                city: { type: "string" } },
                  required: %w[id name city],
                }
  def properties
    render json: Property.order(:name).pluck(:id, :name, :city)
                         .map { |id, name, city| { id:, name:, city: } }
  end

  description "Check which room types are free at one hotel for a date range."
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
                  properties: { id:                  { type: "integer" },
                                name:                { type: "string" },
                                nightly_price_cents: { type: "integer" } },
                  required: %w[id name nightly_price_cents],
                }
  def availability
    render json: RoomType.available_at(params[:property_id], params[:check_in], params[:check_out])
                         .select(:id, :name, :nightly_price_cents)
  end

  description "List the bookings belonging to the authenticated principal."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { id:           { type: "string", format: "uuid" },
                                property_id:  { type: "integer" },
                                room_type_id: { type: "integer" },
                                check_in:     { type: "string" },
                                check_out:    { type: "string" },
                                total_cents:  { type: "integer" },
                                status:       { type: "string" } },
                  required: %w[id property_id room_type_id check_in check_out
                               total_cents status],
                }
  def my_bookings
    render json: Booking.owned_by_current_principal
                        .select(:id, :property_id, :room_type_id, :check_in, :check_out,
                                :total_cents, :status)
  end
end
```

A handler sees only assistant-supplied params and runs inside a session whose
`kiosk.current_user_id()` is the authenticated principal. `my_bookings` scopes
by that server-derived UUID — an assistant cannot inject a different `user_id`
to read another principal's bookings.

**4. Declare the write verbs next door (`reserve_room`, `confirm_booking`)**

A controller declares queries OR actions, never both — the verb it is reached by
is a property of the class.

```ruby
# app/controllers/kiosk/reservations_controller.rb
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Action

  description "Hold a room for the authenticated principal. Creates a TTL hold, " \
              "not a confirmed stay — confirm_booking finishes it."
  input_schema type: "object", additionalProperties: false,
               required: %w[property_id room_type_id check_in check_out],
               properties: {
                 property_id:  { type: "integer" },
                 room_type_id: { type: "integer" },
                 check_in:     { type: "string", format: "date" },
                 check_out:    { type: "string", format: "date" },
               }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id:  { type: "string" },
                              total_cents: { type: "integer" } },
                required: %w[booking_id total_cents]
  def reserve_room
    hold = ReserveRoom.call(**reservation_params)   # INSERT booking + kiosk.reservations TTL row
    render json: { booking_id: hold.booking_id, total_cents: hold.total_cents }
  end

  description "Confirm a held booking. Requires a settled payment mandate that " \
              "references this booking, and returns the hotel's confirmation code."
  input_schema  type: "object", additionalProperties: false,
                required: %w[booking_id],
                properties: { booking_id: { type: "string", format: "uuid" } }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id:        { type: "string" },
                              status:            { const: "confirmed" },
                              confirmation_code: { type: "string" } },
                required: %w[booking_id status confirmation_code]
  def confirm_booking
    # Gate 1: ownership — booking.user_id must equal kiosk.current_user_id() AND status='reserved'
    # Gate 2: payment  — a settled payment_mandate whose cart line_items @> [{booking_id:}]
    # A refusal is Rails' idiom, not a Kiosk class:
    #   render json: { error: { code: "forbidden", … } }, status: :forbidden
    #   — the wire turns that into an RFC 9457 problem document whose
    #     top-level `code` is the token an assistant branches on
    booking = ConfirmBooking.call(booking_id: params[:booking_id])
    render json: { booking_id: booking.id, status: "confirmed",
                   confirmation_code: booking.confirmation_code }
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
verbs at all. There is no second way in: `Kiosk::Server::Queries.register` was
removed in 0.3.

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
