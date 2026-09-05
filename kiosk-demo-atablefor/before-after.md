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

atablefor is a Rails 8.1 app that speaks Kiosk. Below is recorded stdout from
`bundle exec rake demo:book` — **2026-08-26**, on a database prepared by
`rake demo:setup`, which `demo:book` does not declare as a prerequisite and so
never runs; that is why the declaration below reads `abridged: none`. What holds
the block is `bin/check-demo-derivations`: every line in it must be a line one
of the declared producers prints, and a line they cannot print reddens the tree.
That is a membership test, and membership runs one way only — it cannot show
that no line is MISSING. So «the task's own stdout, start to finish» is the
`abridged:` field's claim and a human's signature, not something this repository
proves. The identifiers and the seating dates are that run's — the seatings roll
forward daily, so they move with the day it is run — and the `/etc/hosts` line
appears because this machine has no entry for the demo host, which is the
branch the task takes on any checkout that has not added one.

<!-- derived: transcript | task: bundle exec rake demo:book | from: lib/tasks/demo.rake, script/book_flow.rb, script/equihash_register.rb | keys_from: app/controllers/kiosk/dining_room_controller.rb, app/controllers/kiosk/bookings_controller.rb | abridged: none -->
```
  add to /etc/hosts:  127.0.0.1 atablefor.demo.kiosk.tech

── Starting atablefor on http://127.0.0.1:3002 ──
  Server up at http://127.0.0.1:3002

── Running script/book_flow.rb ──

{"http_register":201,"user_id":"43471b56-f279-443d-b711-6ea643bb2fbb","agent_id":"dc899ef2-bf49-4938-a498-4a9f5367164c","date":"2026-08-26","time":"20:00","party_size":2,"booking":{"booking_id":"d75567a9-ccdf-4b07-ba47-27d3fa718f19","restaurant_id":2,"restaurant_table_id":5,"party_size":2,"date":"2026-08-26","time":"20:00","seating_at":"2026-08-26T20:00:00+01:00","status":"confirmed"},"my_bookings":[{"booking_id":"d75567a9-ccdf-4b07-ba47-27d3fa718f19","restaurant_id":2,"restaurant":"Adega da Graça","neighborhood":"Graça","restaurant_table_id":5,"table_label":"Miradouro 1","party_size":2,"status":"confirmed","seating_date":"2026-08-26","seating_time":"20:00","seating_at":"2026-08-26T19:00:00.000+00:00"}]}

── Assertions ──
  ✓  booking.booking_id present (d75567a9-ccdf-4b07-ba47-27d3fa718f19)
  ✓  booking.status == confirmed
  ✓  booking.party_size == 2 (a table for two)
  ✓  my_bookings shows the confirmed booking (id=d75567a9-ccdf-4b07-ba47-27d3fa718f19)
  ✓  the new booking is confirmed in the DB (id=d75567a9-ccdf-4b07-ba47-27d3fa718f19)
  ✓  the booking pins a table + seating instant (restaurant_table_id + seating_at set)

  All assertions passed.
```

The registration toll leaves no line in that transcript, and it is worth naming
because the next section describes it: `http_register` is the code the driver
reports for the **second** POST. The first is refused `402` and
`script/equihash_register.rb` solves what it carries before retrying.

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the atablefor issuer and surface. Capabilities are `[schema, queries, actions]` — no `pay`. A reservation takes no money.
2. **Self-register, and pay the toll** — generated an RSA-2048 keypair and proved possession of the private key: `GET /kiosk/auth/challenge?public_key=<urlencoded pem>` (the query parameter is REQUIRED — without it the endpoint answers `400 missing public_key query parameter`) → sign an RS256 JWS `{aud, nonce, jti, iat}` → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`. **That first POST comes back `402`**, because registration here is uniformly tolled (`c.registration_pow_count = 1`, `config/initializers/kiosk.rb`) — and the 402 is an RFC 9457 problem document carrying a top-level `challenges` array the SERVER minted, so an assistant cannot solve anything in advance. The client solves each challenge with the shipped Equihash solver and re-POSTs the SAME signed body with the proof in the `Kiosk-PoW` header → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen. `script/equihash_register.rb` is those thirty lines.
3. **Check availability** — `GET /kiosk/availability?party_size=2` returned open tables **across the restaurant roster** for the current upcoming seatings (computed in Europe/Lisbon, never stale); found a 20:00 2-top. No SQL sent — the AI assistant called an operator-registered named query.
4. **Book the table** — `POST /kiosk/book_table {restaurant_id:<r>, restaurant_table_id:<t>, date:"<seating date>", time:"20:00", party_size:2}` → HTTP 200, `status:"confirmed"`. The operator confirmed the reservation under the authenticated principal; a table already held for that seating is a clean 409 (finite, can sell out).
5. **Confirm it holds** — `GET /kiosk/my_bookings` → the one confirmed booking, scoped to this principal alone.

The database confirmed: one row in `bookings` (`status='confirmed'`), pinning the chosen table and seating instant (a unique index makes the seating sell out honestly).

The business outcome: the user said "book a table for two tonight at 8." Their assistant completed the reservation — discovery, registration, availability across the roster, booking — without the user touching anything and without the user having an account at atablefor beforehand. The neighbourhood is deliberately NOT part of this story: `script/book_flow.rb` sends `party_size` alone and takes the first 20:00 row the roster offers, which in the run above was Adega da Graça in Graça. `availability` does accept a `neighborhood` filter, and refuses an unserved one with a typed 400 naming the served ones — this driver simply does not use it.

The operator outcome: atablefor received a real, accountable reservation. The customer relationship stays with the operator (the token carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## Accountability without a payment rail — pricing the scalper, not the diner

A table-booking operator's real fear is not payment fraud (there is no payment) — it is **reservation-scalping**: scripts that mass-claim prime-time 2-tops to resell, and bots that hold tables they never intend to use. Kiosk lets atablefor price exactly that abuse at the door, without blocking legitimate AI assistants.

- **PoW as a metered toll** (`rake demo:pow`). The operator gates the `availability` query behind an Equihash proof-of-work. A script probing prime-time inventory at scale pays a real, per-query cost; a single diner's AI assistant pays it once and moves on. PoW is a metered toll, tuned per operator — not a hardware wall. The task runs at TOY parameters by default (n=96 k=5, a sub-second solve) so it stays runnable anywhere; `KIOSK_POW_DIFFICULTY=high rake demo:pow` runs the same flow at the shipped n=168 k=7 that the hosted atablefor charges, at roughly 10 s and 1.3 GiB per proof on the reference solver — that GiB is its sorted-nonce table, not a floor those params impose on every solver, since a memory-optimised solver trades the table for time. The task prints which of the two it ran at, and asserts it against the challenge the server issued.
- **Trust earned by booking** (`rake demo:reputation`). The PoW cost is *escalating for the unproven and cheaper for the proven*: a fresh or low-reputation AI assistant pays 2 proofs to look at availability, 1 proof after its first confirmed booking, and gets a free pass once it has a real booking history. A scalper renting fresh identities pays and pays; a returning diner earns relief. The reputation factor is a real DB lookup — `COUNT(*)` of the principal's confirmed bookings — not a fake dial.

Isolation is enforced at the app layer: an AI assistant sees and cancels **only its own** bookings (`rake demo:isolation`, `rake demo:redteam`). A cross-tenant read, a cross-owner cancel, and a forged `user_id` argument are all denied.

---

## What's needed — the operator adoption recipe

The delta between "today's reservation platform" and "atablefor" is an operator-side integration. The pieces:

**1. Add the Kiosk satellite gems**

<!-- derived: snippet | from: Gemfile | abridged: the kiosk gem lines and json_schemer only; the Rails/Postgres/dev-group lines around them are out -->
```ruby
# Gemfile
gem "kiosk-all",                path: "../kiosk-all"
gem "kiosk-core",               path: "../kiosk-core"
gem "kiosk-rls",                path: "../kiosk-rls"
gem "kiosk-server",             path: "../kiosk-server"
gem "kiosk-pow-equihash",       path: "../kiosk-pow-equihash"
gem "kiosk-redteam",            path: "../kiosk-redteam"
gem "kiosk-reputation",         path: "../kiosk-reputation"
gem "kiosk-user-idp-devise",    path: "../kiosk-user-idp-devise"

gem "json_schemer"
```

Those are this demo's own `Gemfile` lines, verbatim (the `path:` overrides are
the monorepo checkout; in production they are versioned RubyGems). Not all eight
are the minimum: `kiosk-core` + `kiosk-server` is the engine, `kiosk-pow-equihash`
and `kiosk-reputation` are what the anti-scalping toll below needs,
`kiosk-user-idp-devise` is what `demo:binding` needs, `kiosk-redteam` is the
shared adversarial harness that `script/redteam_suite.rb` drives, `kiosk-rls` is
the optional Postgres backstop, and `json_schemer` is required only because this
origin turns `c.validate_requests` on.

**2. Run the generator**

<!-- derived: generator | from: kiosk-server/lib/generators/kiosk/install/install_generator.rb | why: a command an adopter types, held to the namespace that generator answers — derived from its path and again from its class nesting, so a rename fails here rather than rotting in three documents at once (K-1099) -->
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

**The snippet below is ABRIDGED, and every abridgement is marked where it
happens.** It was DERIVED from
`kiosk-demo-atablefor/app/controllers/kiosk/dining_room_controller.rb` by
deleting text, never by rewriting it. Every line below is a line of that file
with its `description` cut out and nothing else altered — no rewording, no
reordering, nothing invented — and the two kinds of elision marker say so on
their own line. Two things were deleted. (1) Each verb's prose
`description`, collapsed to a `description "…"   # elided` line, and every
`description:` key inside a schema — both are long enough to bury the shape, and
neither changes what the verb accepts or answers. (2) The middle of
`availability`'s body, at an explicit `BODY ELIDED` marker. Everything else —
field names, types, `required` lists, `minimum`/`maximum` bounds,
`example_params`, `example_row` and the guards — is the shipped declaration.

<!-- derived: snippet | from: app/controllers/kiosk/dining_room_controller.rb | transform: strip_descriptions | abridged: each verb's prose description, every schema description: key, and availability's body at a marked BODY ELIDED line -->
```ruby
# app/controllers/kiosk/dining_room_controller.rb
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 # THE SAME DECLARED CEILING `book_table` carries —
                 # a party this verb would SHOW a table for is one that verb can
                 # book, so the two descriptors have to agree. It is the width of
                 # `restaurant_tables.capacity`, the column the filter compares
                 # against, and not an invented house limit.
                 party_size:   { type: "integer", minimum: 1,
                                 maximum: WireArguments::MAX_INT4 },
                 # The served set is DB-derived (an operator adds one by
                 # inserting a restaurant), so it cannot be an `enum` here and
                 # the handler guard is the only place the refusal can live.
                 neighborhood: { type: "string" },
                 # A CLOSED SET, so an `enum` and not a pattern — the
                 # refusal is then the schema layer's, uniformly, rather than an
                 # empty list an assistant cannot tell from a sold-out night.
                 time:         { type: "string", enum: Seatings::TIMES },
                 date:         { type: "string", format: "date" },
               },
               required: ["party_size"]
  # One row per open (restaurant, table, seating). A bare array: this verb does
  # not paginate, so there is no `next` and nothing to echo back. `neighborhood`
  # and `cuisine` are nullable and travel as null rather than being dropped.
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
                  required: %w[restaurant neighborhood cuisine restaurant_id restaurant_table_id
                               table_label capacity seating_date seating_time seating_at deposit_eur],
                }
  example_params({ party_size: 2, neighborhood: "Alfama" })
  # The seating is RESOLVED, not written down: this row is what an
  # assistant carries straight into `book_table`, whose own guard refuses a
  # seating that has passed. See {Seatings.example_date}.
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: -> { Seatings.example_date.iso8601 }, seating_time: Seatings::TIMES[1],
    seating_at: -> { Seatings.seating_at(Seatings.example_date, Seatings.example_time).iso8601 },
    deposit_eur: 10,
  })
  def availability
    # An ABSENT party_size and a present-but-unusable one are two different
    # mistakes with two different messages. Both sentences live in
    # {WireArguments} — the second because `book_table` answers with it too, and
    # the two halves must not drift.
    return render_refusal(WireArguments.missing_party_size) unless params.key?(:party_size)

    party_size, refusal = WireArguments.party_size(params[:party_size])
    return render_refusal(refusal) if refusal

    # An unserved neighbourhood is a typed 400 naming the served ones,
    # not `200 []`. `Restaurant.served_neighborhoods` is read once, so the
    # refusal and the query below can never name different sets.
    nbhd_filter, refusal = WireArguments.neighborhood(params[:neighborhood],
                                                      Restaurant.served_neighborhoods)
    return render_refusal(refusal) if refusal

    # ── BODY ELIDED HERE (this comment is the document's, not the file's) ──
    # What follows in the shipped file is the rest of this method: the two more
    # typed guards (`WireArguments.seating_time`, `WireArguments.seating_date`)
    # over the rolling `Seatings.upcoming` roster, the capacity-filtered
    # `RestaurantTable.joins(:restaurant)` catalogue, and the subtraction of the
    # (table, seating) pairs a confirmed `Booking` already holds — keyed on the
    # absolute instant so a timezone cannot make the match miss. It ends with
    # the lines below, which ARE the shipped ones.
    render json: rows
  end

  # my_bookings — per-user booking list scoped by the session GUC. The scope is
  # provider-controlled; the agent supplies no filter. The principal can only
  # see rows where user_id matches kiosk.current_user_id(), enforced in the
  # query itself — `owned_by_current_principal` is the ONE place that predicate
  # is written.
  # ADR-0023: semantics only; naming the follow-on VERB in the description is
  # the sanctioned form, naming its argument is not.
  kind :query
  description "…"   # elided — see the shipped file
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A bare array, seating-time ordered. `seating_date`/`seating_time` are the
  # LOCAL (Europe/Lisbon) spelling of the same instant `seating_at` carries, so
  # all three are always present rather than one being derivable.
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
                  required: %w[booking_id restaurant_id restaurant neighborhood restaurant_table_id
                               table_label party_size status seating_date seating_time seating_at],
                }
  def my_bookings
    render json: Booking.owned_by_current_principal
                        .joins(:restaurant, :restaurant_table)
                        .order(:seating_at)
                        .pluck("bookings.id", "bookings.restaurant_id", "restaurants.name",
                               "restaurants.neighborhood", "bookings.restaurant_table_id",
                               "restaurant_tables.label", "bookings.party_size", "bookings.status",
                               "bookings.seating_at")
                        .map { |id, restaurant_id, restaurant, neighborhood,
                                 table_id, table_label, party_size, status, seating_at|
                          # The seating's LOCAL date and time, from the same
                          # `Seatings.zone` that decides which seatings exist
                          # at all, so the two cannot drift.
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

Derived from
`kiosk-demo-atablefor/app/controllers/kiosk/bookings_controller.rb` the same way
as the read snippet: every line is that file's with its `description` cut out
and nothing else altered, and the two `description "…"   # elided` markers say
so. Nothing else is left out — both write verbs fit whole.

<!-- derived: snippet | from: app/controllers/kiosk/bookings_controller.rb | transform: strip_descriptions | abridged: both verbs' prose descriptions and every schema description: key -->
```ruby
# app/controllers/kiosk/bookings_controller.rb
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # book_table — reserve a specific table at a chosen restaurant for a chosen
  # upcoming seating, for the authenticated principal. The (restaurant_id,
  # restaurant_table_id) come from an availability row; the (date, time) seating
  # is re-validated through the same app/models/seatings.rb helper `availability`
  # filters with, so it must be one of the CURRENT upcoming seatings.
  # Contention is finite: a UNIQUE index on (restaurant_table_id, seating_at)
  # among confirmed rows makes a table already held a clean 409 Conflict. No
  # payment — any deposit shown is settled at the restaurant.
  # ADR-0023: the description says WHAT booking means and WHEN it is refused; it
  # names no argument — `input_schema` below declares all five.
  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 restaurant_id:       { type: "integer", minimum: 1 },
                 restaurant_table_id: { type: "integer", minimum: 1 },
                 date:                { type: "string", format: "date" },
                 time:                { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$" },
                 # THE CEILING IS DECLARED, not merely enforced — a
                 # refusal the published schema does not predict is its own
                 # defect. It is the width of `bookings.party_size` (and of the
                 # `restaurant_tables.capacity` this is compared against), so it
                 # is the column's own bound and not an invented house limit.
                 party_size:          { type: "integer", minimum: 1,
                                        maximum: WireArguments::MAX_INT4 },
               },
               required: ["restaurant_id", "restaurant_table_id", "date", "time", "party_size"]
  # An action answers its own object. The five arguments come back echoed
  # because a confirmation an assistant reads back to its human has to name WHAT
  # was booked; `seating_at` is the absolute instant behind the (date, time).
  output_schema type: "object",
                additionalProperties: false,
                properties: {
                  booking_id:          { type: "string" },
                  restaurant_id:       { type: "integer" },
                  restaurant_table_id: { type: "integer" },
                  party_size:          { type: "integer" },
                  date:                { type: "string" },
                  time:                { type: "string" },
                  seating_at:          { type: "string" },
                  status:              { type: "string" },
                },
                required: %w[booking_id restaurant_id restaurant_table_id party_size
                             date time seating_at status]
  # THE SEATING IS RESOLVED, NOT WRITTEN DOWN. A calendar literal here
  # ages into a 400 the day that seating passes, so `example_params` and
  # `example_row` are RESOLVABLE slots ({Kiosk::Server::SchemaSlots}) naming the
  # same {Seatings} helpers `availability` uses — the three cannot drift.
  example_params({
    restaurant_id: 1, restaurant_table_id: 1,
    date: -> { Seatings.example_date.iso8601 }, time: Seatings::TIMES[1], party_size: 2,
  })
  example_row({
    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
    restaurant_id: 1, restaurant_table_id: 1, party_size: 2,
    date: -> { Seatings.example_date.iso8601 }, time: Seatings::TIMES[1],
    seating_at: -> { Seatings.seating_at(Seatings.example_date, Seatings.example_time).iso8601 },
    status: "confirmed",
  })
  def book_table
    render_operation BookTableOperation.call(
      principal_id:        kiosk_identity.user_id,
      restaurant_id:       params[:restaurant_id],
      restaurant_table_id: params[:restaurant_table_id],
      date:                params[:date],
      time:                params[:time],
      party_size:          params[:party_size],
    )
  end

  # cancel_booking — cancel one of the authenticated principal's own bookings,
  # freeing the (table, seating) so it can be booked again. Owner-scoped: the
  # WHERE gates on `user_id = kiosk.current_user_id()`, so a cross-principal
  # cancel is a clean 403 — the booking is not found under the caller's identity.
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
                  booking_id: { type: "string" },
                  status:     { type: "string" },
                },
                required: %w[booking_id status]
  def cancel_booking
    render_operation CancelBookingOperation.call(booking_id: params[:booking_id])
  end
end
```

`KioskRefusals` is the app's own concern, not a Kiosk class: it turns an
Operation's result into a `render`. A refused `book_table` — the table was taken
between the availability read and the write — becomes `render json: { error: {
code: "conflict", … } }, status: :conflict`, and the wire carries that `code`
into an RFC 9457 problem document. Neither verb takes a principal: `book_table`
reads it off the identity the wire resolved (`kiosk_identity.user_id`) and
`CancelBookingOperation`'s WHERE gates on `kiosk.current_user_id()`, so a
cross-principal cancel finds nothing under the caller's identity.

Handlers are plain Rails actions: your filters, your `rescue_from`, your `params`. The `kiosk.current_user_id()` Postgres function returns the ID of the principal the wire authenticated — the assistant's own account by default, and the HUMAN's after `demo:binding` re-binds that assistant to a diner's Devise account — and the handler enforces owner-scope with it, so an AI assistant cannot cancel or read another principal's booking.

**5. Name the controllers in the initializer**

<!-- derived: snippet | from: config/initializers/kiosk.rb | abridged: the handler-naming lines only, out of the whole Kiosk.configure block -->
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

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or a migration on any table you already own. The satellite gems add a parallel surface in their own `kiosk.*` schema; your tables keep their columns and your human-facing app keeps working unchanged.

What it DOES touch, and this demo is honest about it because an adopter will hit it on day one: two small additions to `app/models/booking.rb`, an operator model. `owned_by_current_principal` (`:40`) is the scope every owner-scoped read goes through — one `Arel.sql` predicate over `kiosk.current_user_id()`, written once so the app-layer check and the optional RLS policy are literally the same expression — and `publish_instant` (`:52`) pins the byte-level shape of a `timestamptz` on the wire. Both are a few lines, neither changes the schema, and both are the sort of thing you would write anyway to expose a model over any API.

**What this enables:** any personal AI assistant that has discovered the `issuer` and `endpoint` via `/.well-known/kiosk.json` can complete a reservation without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic and prices scalping at the door; the anti-bot wall stays in place for everything else.
