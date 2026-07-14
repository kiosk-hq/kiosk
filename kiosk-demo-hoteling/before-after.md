# Before and After — why agents stall at Booking.com, and what hoteling proves

**Honesty note up front.** hoteling is what Booking.com *would* look like if it spoke Kiosk — a fake-but-realistic hotel-booking provider built to demonstrate the mechanism. Nothing below implies that real Booking.com works this way. The demo proves the *mechanism* works; whether providers will adopt it is an open question.

---

## Before — a real agent on real Booking.com today

Every current personal agent (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same wall: the connector stops at discovery.

**The Booking.com connector probed in-session confirms the end-state** (`docs/research/2026-06-22-consumer-agent-validation.md`, Front A):

> Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) **stop at discovery.** Their terminal step is a deep link back to the provider's own app/site, where the human must register and pay.

The Booking.com MCP connector exposes two tools: `accommodations_search` (returns property listings) and `answer_property_qa_by_ids` (answers natural-language questions about specific properties). The session schema's own `deeplink_id` field describes navigating *to* Booking.com — confirming the intended flow: **the agent shows options, then deep-links the user out to Booking.com to register, authenticate, and pay.** There is no reserve, no checkout, no payment tool.

**The structural root cause is economic, not technical.** Booking.com's business model depends on an authenticated in-app session: display advertising, metasearch fees, loyalty points, and first-party data capture all require the human to complete the booking inside Booking.com's own funnel. A silent agent reservation via a structured API erases that session entirely. The discovery step *is* the product.

Anti-bot friction compounds this. Behavioral fingerprinting (Cloudflare Turnstile) flags agent traffic; the user's payment instrument lives outside the agent's context; and EU/UK PSD2 SCA requires a biometric or device-OTP challenge on first use that only the human can satisfy.

**In short:** the agent discovers available hotels, then hands back to the human. The human navigates to Booking.com, creates or logs into an account, passes bot checks, authenticates, and pays. The agent's contribution is a glorified search result.

---

## With Kiosk — hoteling (`rake demo` output)

hoteling is a Rails 8.1 app that speaks Kiosk. The following is the recorded output of `rake demo`.

```
  Registered: user_id=<uuid>
  Properties: 5 found, using id=1 (Gran Hotel Istanbul)
  Availability: 3 room type(s) available, using id=1 (Standard, 8000c/night)
  Reserved: booking_id=<uuid> total=24000c
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

**What the agent did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the hoteling issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, then completed the proof-of-possession handshake: `GET /kiosk/auth/challenge` → signed the challenge as an RS256 JWS (`aud` = the hoteling issuer) → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}` → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No bot check.
3. **Browse** — `POST /kiosk/query {name:"properties"}` returned 5 hotel properties. `POST /kiosk/query {name:"availability", property_id:1, check_in:"2026-07-28", check_out:"2026-07-31"}` returned available room types with nightly prices.
4. **Reserve** — `POST /kiosk/run {name:"reserve_room", property_id:1, room_type_id:1, check_in:"2026-07-28", check_out:"2026-07-31"}` → HTTP 200, `booking_id:<uuid>`, `total_cents:24000`. A TTL hold was created in `kiosk.reservations`.
5. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:24100`, `scope:"lodging"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:24000`, `line_items:[{sku:"Standard", qty:3, booking_id:<uuid>}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws:…, cart_mandate_jws:…, payment_mandate_jws:…}` → `settled_amount_cents:24000`, `ok:true`.
6. **Confirm** — `POST /kiosk/run {name:"confirm_booking", booking_id:<uuid>}` → HTTP 200, `status:"confirmed"`, `confirmation_code:<uuid>`. The server verified ownership (Gate 1) and the settled mandate referencing this booking (Gate 2) before confirming.

The database confirmed: one row in `bookings` with `status='confirmed'`, one row in `kiosk.settlements`, one row in `kiosk.reservations`.

The business outcome: the user said "book a hotel room for next month." Their assistant completed the full booking — discovery, registration, room selection, reservation, payment, confirmation — without the user touching anything and without the user having an account at hoteling beforehand.

The provider outcome: hoteling received a confirmed booking and a settled payment. The customer relationship stays with hoteling (the mandate carries the provider's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake provider with a stub payment processor.** The mechanism works. Whether real providers will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the provider adoption recipe

The delta between "today's Booking.com" and "hoteling" is a provider-side integration. The pieces:

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

This emits exactly two things: `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the seven `kiosk.*` schema migrations (the namespace with agents, sessions, actions-log, reservations, device-authorizations, mandate tables, plus the KYC column). Run `bin/rails db:migrate` to apply them.

The generator does **not** touch your routes. `kiosk-server` ships the wire controllers; you mount them yourself. In this demo that block lives in `config/routes.rb`:

```ruby
# config/routes.rb — the wire surface, mounted manually (v0.1 alpha).
# REST endpoints (ADR-0005): one per verb, HTTP method carries the semantics.
get  "/kiosk/schema",         to: "kiosk/server/wire#schema"
post "/kiosk/query",          to: "kiosk/server/wire#query"
post "/kiosk/run",            to: "kiosk/server/wire#run"
post "/kiosk/pay",            to: "kiosk/server/wire#pay"
get  "/kiosk/auth/challenge", to: "kiosk/server/auth#challenge"
post "/kiosk/auth/register",  to: "kiosk/server/auth#register"
post "/kiosk/auth/login",     to: "kiosk/server/auth#login"
post "/kiosk/auth/revoke",    to: "kiosk/server/auth#revoke"

# /.well-known/kiosk.json is built on the fly from Kiosk.configuration;
# kiosk-server does not yet ship a controller for it, so it is inlined here.
get "/.well-known/kiosk.json", to: ->(env) {
  base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
  [200, { "content-type" => "application/json" },
   [Kiosk::Server::WellKnown.build_json(base_url: base_url)]]
}
```

(A follow-up release will mount these via the engine's own routes drawer so this block collapses to one line.)

**3. Register named queries**

Register the queries you want to expose to agents:

```ruby
Kiosk::Server::Queries.register("properties",
  description: "Browse all available hotel properties") do |_params|
  Property.select(:id, :name, :city).order(:name)
end

Kiosk::Server::Queries.register("availability",
  description: "Check room availability at a property for given dates",
  params: { property_id: "integer", check_in: "date YYYY-MM-DD", check_out: "date YYYY-MM-DD" }) do |params|
  RoomType.where(property_id: params[:property_id])
          .where.not(id: Booking.where(property_id: params[:property_id],
                                       status: %w[reserved confirmed])
                                .where("check_in < ? AND check_out > ?",
                                       params[:check_out], params[:check_in])
                                .select(:room_type_id))
          .select(:id, :name, :nightly_price_cents)
end

Kiosk::Server::Queries.register("my_bookings",
  description: "List this principal's hotel bookings (scoped to authenticated user)") do |_params|
  Booking.where("user_id = kiosk.current_user_id()")
         .select(:id, :property_id, :room_type_id, :check_in, :check_out, :total_cents, :status)
end
```

The handler block receives only agent-supplied params and runs inside a session whose `kiosk.current_user_id()` is the authenticated principal. `my_bookings` scopes by the server-derived user UUID — agents cannot inject a different `user_id` to read other users' bookings.

**4. Register Actions (`reserve_room` and `confirm_booking`)**

```ruby
Kiosk::Server::Actions.register("reserve_room",
  description: "Reserve a room for the authenticated principal (creates a TTL hold)",
  params: { property_id: "integer", room_type_id: "integer",
            check_in: "date YYYY-MM-DD", check_out: "date YYYY-MM-DD" }) do |args|
  uid = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  # ... calculate nights, total_cents, INSERT booking + kiosk.reservations TTL row
  { booking_id: booking.id, total_cents: total_cents }
end

Kiosk::Server::Actions.register("confirm_booking",
  description: "Confirm a reserved booking (requires payment mandate referencing this booking)",
  params: { booking_id: "uuid" }) do |args|
  # Gate 1: ownership — booking.user_id must equal kiosk.current_user_id() AND status='reserved'
  # Gate 2: payment  — a settled payment_mandate whose cart line_items @> [{booking_id:}]
  # Both must pass; else Forbidden.
  { booking_id:, status: "confirmed", confirmation_code: SecureRandom.uuid }
end
```

Gate 1 (ownership) and Gate 2 (payment binding) together form the C2 defense: B cannot confirm A's booking even if B paid a mandate referencing A's booking_id. The ownership check fires first.

**5. Wire a payment-provider adapter**

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer           = "https://hoteling.app"
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(api_key: ENV["STRIPE_SECRET_KEY"])
end
```

The stub PSP (`StubPsp`, a `Kiosk::PaymentProviders::Base` subclass) used in the demo can be swapped for the Stripe adapter without touching any other code.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the provider's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal agent that has read `KIOSK.skill.md` — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a hotel booking without the user having an account at the provider and without the user being present. The provider drops its anti-bot wall for sanctioned agent traffic; the anti-bot wall stays in place for everything else.

---

*Validation research source: `docs/research/2026-06-22-consumer-agent-validation.md` — primary evidence from live connector probes (Booking.com) as of 2026-06-22. The Booking.com connector finding (search + QA only, no reserve/checkout tool) was confirmed in-session via MCP tool introspection.*
