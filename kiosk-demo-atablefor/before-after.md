# Before and After — why AI assistants stall at restaurant booking, and what atablefor proves

**Honesty note up front.** atablefor is what a restaurant-reservation platform *would* look like if it spoke Kiosk — a fake-but-realistic table-booking aggregator (a handful of coined Lisbon restaurants) built to demonstrate the mechanism. Nothing below implies that any real reservation platform works this way. The demo proves the *mechanism* works; whether operators will adopt it is an open question.

---

## Before — a real AI assistant booking a table today

Every current personal AI assistant (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same walls when asked to book a restaurant table: the anti-bot screen and the account/verification gate.

**Anti-bot friction documented in validation research:**

> Documented ChatGPT-Agent commerce tasks take **6–20 minutes** (2–3× human) and stop at the **anti-bot screen, login, or verification** — the AI assistant opens a user browser to finish.

The structural root cause is a stack of incompatible requirements: behavioural fingerprinting (Cloudflare Turnstile, DataDome) flags AI-assistant traffic; OTP walls assume a human-held device; the reservation platform wants an authenticated account tied to a phone number to hold the table against no-shows; and prime-time inventory is guarded precisely because it is scarce and scalped.

**The end-state the incumbents ship confirms the pattern:**

The reservation connectors available to AI assistants today **stop at discovery**. Their terminal step is a deep link back to the platform's own app/site, where the human must sign in, pass the bot check, and confirm the booking. There is no first-class "confirm this reservation" tool exposed to the AI assistant.

The reason incumbents stay at discovery is economic, not technical. A reservation platform's product is the authenticated funnel — the account, the loyalty profile, the cover-fee and no-show economics, and the ability to price and throttle prime-time inventory against scalpers. A silent AI-assistant booking through a structured API erases that funnel. The discovery step *is* the product.

**In short:** the AI assistant finds where to book, then hands back to the human. The human signs in, passes bot checks, verifies a phone, and confirms. The AI assistant's contribution is a glorified search result.

---

## With Kiosk — atablefor (`rake demo:book` output)

atablefor is a Rails 8.1 app that speaks Kiosk. The following is the recorded output of a `rake demo:book` run.

```
{"http_register":201,"user_id":"cd10cd63-c869-459b-9fd0-48955a94139e","agent_id":"e500a8dc-440e-4540-8906-38339e3692ab","date":"2026-08-08","time":"20:00","party_size":2,"booking":{"booking_id":"2840211e-e0d0-4a16-a93c-8261176d407e","restaurant_id":2,"restaurant_table_id":5,"party_size":2,"date":"2026-08-08","time":"20:00","seating_at":"2026-08-08T20:00:00+01:00","status":"confirmed"},"my_bookings":[{"booking_id":"2840211e-e0d0-4a16-a93c-8261176d407e","restaurant_id":2,"restaurant":"Adega da Graça","neighborhood":"Graça","restaurant_table_id":5,"table_label":"Miradouro 1","party_size":2,"status":"confirmed","seating_date":"2026-08-08","seating_time":"20:00","seating_at":"2026-08-08T19:00:00.000+00:00"}]}

── Assertions ──
  ✓  booking.booking_id present (2840211e-e0d0-4a16-a93c-8261176d407e)
  ✓  booking.status == confirmed
  ✓  booking.party_size == 2 (a table for two)
  ✓  my_bookings shows the confirmed booking (id=2840211e-e0d0-4a16-a93c-8261176d407e)
  ✓  the new booking is confirmed in the DB (id=2840211e-e0d0-4a16-a93c-8261176d407e)
  ✓  the booking pins a table + seating instant (restaurant_table_id + seating_at set)

  All assertions passed.
```

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the atablefor issuer and surface. Capabilities are `[schema, queries, actions]` — no `pay`. A reservation takes no money.
2. **Self-register** — generated an RSA-2048 keypair, proved possession of the private key (`GET /kiosk/auth/challenge` → sign an RS256 JWS `{aud, nonce, jti, iat}` → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`) → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Check availability** — `GET /kiosk/availability?party_size=2` returned open tables **across the restaurant roster** for the current upcoming seatings (computed in Europe/Lisbon, never stale); found a 20:00 2-top. No SQL sent — the AI assistant called an operator-registered named query.
4. **Book the table** — `POST /kiosk/book_table {restaurant_id:<r>, restaurant_table_id:<t>, date:"<seating date>", time:"20:00", party_size:2}` → HTTP 200, `status:"confirmed"`. The operator confirmed the reservation under the authenticated principal; a table already held for that seating is a clean 409 (finite, can sell out).
5. **Confirm it holds** — `GET /kiosk/my_bookings` → the one confirmed booking, scoped to this principal alone.

The database confirmed: one row in `bookings` (`status='confirmed'`), pinning the chosen table and seating instant (a unique index makes the seating sell out honestly).

The business outcome: the user said "book a table for two in Alfama tonight at 8." Their assistant completed the reservation — discovery, registration, availability across the roster, booking — without the user touching anything and without the user having an account at atablefor beforehand.

The operator outcome: atablefor received a real, accountable reservation. The customer relationship stays with the operator (the token carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## Accountability without a payment rail — pricing the scalper, not the diner

A table-booking operator's real fear is not payment fraud (there is no payment) — it is **reservation-scalping**: scripts that mass-claim prime-time 2-tops to resell, and bots that hold tables they never intend to use. Kiosk lets atablefor price exactly that abuse at the door, without blocking legitimate AI assistants.

- **PoW as a metered toll** (`rake demo:pow`). The operator gates the `availability` query behind an Equihash proof-of-work. A script probing prime-time inventory at scale pays a real, per-query cost; a single diner's AI assistant pays it once and moves on. PoW is a metered toll, tuned per operator — not a hardware wall.
- **Trust earned by booking** (`rake demo:reputation`). The PoW cost is *escalating for the unproven and cheaper for the proven*: a fresh or low-reputation AI assistant pays 2 proofs to look at availability, 1 proof after its first confirmed booking, and gets a free pass once it has a real booking history. A scalper renting fresh identities pays and pays; a returning diner earns relief. The reputation factor is a real DB lookup — `COUNT(*)` of the principal's confirmed bookings — not a fake dial.

Isolation is enforced at the app layer: an AI assistant sees and cancels **only its own** bookings (`rake demo:isolation`, `rake demo:redteam`). A cross-tenant read, a cross-owner cancel, and a forged `user_id` argument are all denied.

---

## What's needed — the operator adoption recipe

The delta between "today's reservation platform" and "atablefor" is an operator-side integration. The pieces:

**1. Add the Kiosk satellite gems**

```ruby
# Gemfile
gem "kiosk-core",   path: "../kiosk-core"
gem "kiosk-rls",    path: "../kiosk-rls"
gem "kiosk-server", path: "../kiosk-server"
```

In production these are versioned RubyGems.

**2. Run the generator**

```
rails g kiosk:install
```

This emits `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the `kiosk.*` schema migrations. Run `bin/rails db:migrate` to apply them. The generator does **not** touch your routes; `kiosk-server` ships the wire controllers and you mount them yourself (see `config/routes.rb`).

**3. Declare the read verbs in a controller**

The verbs an assistant may call are ordinary Rails controller actions. Kiosk
ships a MIXIN, not a base class — which superclass a handler has is your
decision — and each class-level macro is claimed by the next `def`, so a method
with no macros above it is a helper the wire cannot see. `input_schema` and
`output_schema` are REQUIRED on every verb: a declaration missing either raises
as the class body is read, so the app does not boot.

**The snippet below is ABRIDGED, not invented:** each verb's full prose
`description` and its per-property `description` lines are elided, and
`availability`'s row-building body is summarised rather than reproduced. Every
field name, type and `required` list is the shipped one verbatim — read
`kiosk-demo-atablefor/app/controllers/kiosk/dining_room_controller.rb` for the
whole thing.

```ruby
# app/controllers/kiosk/dining_room_controller.rb
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals   # the app's own concern: renders a refusal result

  kind :query
  description "Find tables still open across all restaurants for the upcoming " \
              "(rolling, Lisbon-tz) seatings that seat a given party. Each row " \
              "carries a `restaurant_id` and a `restaurant_table_id`; pass both " \
              "to book_table, with the row's `seating_date` and `seating_time` " \
              "as its `date` and `time`."
  input_schema type: "object", additionalProperties: false,
               required: %w[party_size],
               properties: {
                 party_size:   { type: "integer", minimum: 1 },
                 neighborhood: { type: "string" },
                 date:         { type: "string", format: "date" },
                 time:         { type: "string", enum: Seatings::TIMES },
               }
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    restaurant:          { type: "string" },
                    neighborhood:        { type: %w[string null] },
                    cuisine:             { type: %w[string null] },
                    restaurant_id:       { type: "integer" },
                    restaurant_table_id: { type: "integer" },
                    table_label:         { type: "string" },
                    capacity:            { type: "integer" },
                    seating_date:        { type: "string" },
                    seating_time:        { type: "string" },
                    seating_at:          { type: "string" },
                    deposit_eur:         { type: "integer" },
                  },
                  required: %w[restaurant neighborhood cuisine restaurant_id
                               restaurant_table_id table_label capacity
                               seating_date seating_time seating_at deposit_eur],
                }
  def availability
    party_size, refusal = WireArguments.party_size(params[:party_size])
    return render_refusal(refusal) if refusal

    # BODY SUMMARISED — the shipped file spells out the rolling Europe/Lisbon
    # seating roster (`Seatings.upcoming`), the typed 400s an unserved
    # neighbourhood or an out-of-horizon date get instead of a misleading empty
    # list, the capacity-filtered `RestaurantTable.joins(:restaurant)` catalogue,
    # and the subtraction of the (table, seating) pairs a confirmed `Booking`
    # already holds. What it builds is one hash per still-free (table, seating),
    # and THAT is what has to satisfy the output_schema above:
    #
    #   { restaurant:, neighborhood:, cuisine:, restaurant_id:, restaurant_table_id:,
    #     table_label:, capacity:, seating_date:, seating_time:, seating_at:, deposit_eur: }
    render json: rows
  end

  kind :query
  description "List this principal's table bookings across every restaurant on the " \
              "aggregator, scoped to the authenticated account and un-filterable by " \
              "the caller. Cancelled bookings stay listed rather than disappearing. " \
              "Once the human picks a row, `cancel_booking` calls it off."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    booking_id:          { type: "string" },
                    restaurant_id:       { type: "integer" },
                    restaurant:          { type: "string" },
                    neighborhood:        { type: %w[string null] },
                    restaurant_table_id: { type: "integer" },
                    table_label:         { type: "string" },
                    party_size:          { type: "integer" },
                    status:              { type: "string" },
                    seating_date:        { type: "string" },
                    seating_time:        { type: "string" },
                    seating_at:          { type: "string" },
                  },
                  required: %w[booking_id restaurant_id restaurant neighborhood
                               restaurant_table_id table_label party_size status
                               seating_date seating_time seating_at],
                }
  def my_bookings
    render json: Booking.owned_by_current_principal
                        .joins(:restaurant, :restaurant_table)
                        .order(:seating_at)
                        .pluck("bookings.id", "bookings.restaurant_id", "restaurants.name",
                               "restaurants.neighborhood", "bookings.restaurant_table_id",
                               "restaurant_tables.label", "bookings.party_size",
                               "bookings.status", "bookings.seating_at")
                        .map { |id, restaurant_id, restaurant, neighborhood,
                                table_id, table_label, party_size, status, seating_at|
                          # The seating's LOCAL date and time, from the same
                          # `Seatings.zone` that decides which seatings exist at
                          # all — so the two cannot drift.
                          local = seating_at.in_time_zone(Seatings.zone)
                          { booking_id:          id,
                            restaurant_id:       restaurant_id,
                            restaurant:          restaurant,
                            neighborhood:        neighborhood,
                            restaurant_table_id: table_id,
                            table_label:         table_label,
                            party_size:          party_size,
                            status:              status,
                            seating_date:        local.strftime("%Y-%m-%d"),
                            seating_time:        local.strftime("%H:%M"),
                            seating_at:          Booking.publish_instant(seating_at) }
                        }
  end
end
```

AI assistants call these by name only, one endpoint per verb (`GET /kiosk/availability?party_size=2`). They never supply SQL. App-layer isolation lives here: owner-scoped queries filter by `kiosk.current_user_id()` (operator-derived from the session, never an AI-assistant param); the availability catalogue is open to all authenticated AI assistants.

**4. Declare the write verbs next door (`book_table`, `cancel_booking`)**

The kind of verb is a property of each DECLARATION (`kind :action` below), not
of the class, so one controller could carry all four. Two is this demo's shape,
not a rule.

Abridged the same way as the read snippet above: the prose `description` and the
per-property `description` lines are elided. Field names, types and `required`
lists are the shipped ones verbatim.

```ruby
# app/controllers/kiosk/bookings_controller.rb
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals   # the app's own concern: turns an Operation result into a render

  kind :action
  description "Reserve one table at one restaurant for one seating, for the " \
              "authenticated principal. This is a COMMITMENT, not a quote. No " \
              "payment is taken. Cancel it with cancel_booking."
  input_schema type: "object", additionalProperties: false,
               required: %w[restaurant_id restaurant_table_id date time party_size],
               properties: {
                 restaurant_id:       { type: "integer", minimum: 1 },
                 restaurant_table_id: { type: "integer", minimum: 1 },
                 date:                { type: "string", format: "date" },
                 time:                { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$" },
                 party_size:          { type: "integer", minimum: 1 },
               }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id:          { type: "string" },
                              restaurant_id:       { type: "integer" },
                              restaurant_table_id: { type: "integer" },
                              party_size:          { type: "integer" },
                              date:                { type: "string" },
                              time:                { type: "string" },
                              seating_at:          { type: "string" },
                              status:              { type: "string" } },
                required: %w[booking_id restaurant_id restaurant_table_id party_size
                             date time seating_at status]
  def book_table
    # The Operation holds the seating re-validation and the INSERT. A table
    # already held for that seating is a clean 409 (the supply is finite):
    # render_operation turns the refused result into
    #   render json: { error: { code: "conflict", … } }, status: :conflict
    # The principal comes from the identity the wire resolved, never an argument.
    render_operation BookTableOperation.call(
      principal_id:        kiosk_identity.user_id,
      restaurant_id:       params[:restaurant_id],
      restaurant_table_id: params[:restaurant_table_id],
      date:                params[:date],
      time:                params[:time],
      party_size:          params[:party_size],
    )
  end

  kind :action
  description "Cancel one of the authenticated principal's own table bookings " \
              "(requires the booking to belong to the principal). Frees the " \
              "(table, seating)."
  input_schema  type: "object", additionalProperties: false,
                required: %w[booking_id],
                properties: { booking_id: { type: "string", format: "uuid" } }
  output_schema type: "object", additionalProperties: false,
                properties: { booking_id: { type: "string" },
                              status:     { type: "string" } },
                required: %w[booking_id status]
  def cancel_booking
    # Owner-scoped, and the principal is not passed in: the Operation's WHERE
    # gates on user_id = kiosk.current_user_id(), so a cross-principal cancel is
    # a clean 403 — the booking is simply not found under the caller's identity.
    render_operation CancelBookingOperation.call(booking_id: params[:booking_id])
  end
end
```

Handlers are plain Rails actions: your filters, your `rescue_from`, your `params`. The `kiosk.current_user_id()` Postgres function returns the synthetic principal's ID, and the handler enforces owner-scope with it, so an AI assistant cannot cancel or read another principal's booking.

**5. Name the controllers in the initializer**

```ruby
Kiosk.configure do |c|
  c.handlers = %w[Kiosk::DiningRoomController Kiosk::BookingsController]
end
```

This line is load-bearing. The wire reaches a handler through the registry and
nothing else in the app references these classes, so in development — where
Rails does not eager-load `app/` — an origin that names none of them serves no
verbs at all. There is no second way in: `Kiosk::Server::Queries.register`, the block API
the 0.3 series shipped, was removed in 0.4 and now raises NoMethodError.

**6. No payment adapter**

There is nothing to wire. atablefor configures no `payment_provider`, so `pay` drops out of the advertised capabilities and the discovery documents carry no payments block. A reservation takes no money — the operator's concern is accountability and anti-scalping, which PoW and reputation handle.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the operator's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal AI assistant that has discovered the `issuer` and `endpoint` via `/.well-known/kiosk.json` can complete a reservation without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic and prices scalping at the door; the anti-bot wall stays in place for everything else.
