# Before and After — why AI assistants stall at restaurant booking, and what atablefor proves

**Honesty note up front.** atablefor is what a restaurant-reservation platform *would* look like if it spoke Kiosk — a fake-but-realistic table-booking operator (Tasca do Tejo) built to demonstrate the mechanism. Nothing below implies that any real reservation platform works this way. The demo proves the *mechanism* works; whether operators will adopt it is an open question.

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
{"http_register":201,"user_id":"3e406ba4-46a0-402d-a5c1-7eadb173db82","agent_id":"e118679e-009e-4458-8bbd-573ccfe0985a","date":"2026-07-21","time":"20:00","party_size":2,"booking":{"booking_id":"18aaacf8-1e7e-484c-b02d-76f578854418","restaurant_id":1,"table_slot_id":1,"party_size":2,"date":"2026-07-21","time":"20:00","status":"confirmed"},"my_bookings":[{"id":"18aaacf8-1e7e-484c-b02d-76f578854418","restaurant_id":1,"table_slot_id":1,"party_size":2,"status":"confirmed","slot_date":"2026-07-21","slot_time":"20:00"}]}

── Assertions ──
  ✓  booking.booking_id present (18aaacf8-1e7e-484c-b02d-76f578854418)
  ✓  booking.status == confirmed
  ✓  booking.party_size == 2 (a table for two)
  ✓  my_bookings shows the confirmed booking (id=18aaacf8-1e7e-484c-b02d-76f578854418)
  ✓  confirmed bookings count = 1
  ✓  exactly 1 table_slot marked booked

  All assertions passed.
```

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the atablefor issuer and surface. Capabilities are `[schema, query, run]` — no `pay`. A reservation takes no money.
2. **Self-register** — generated an RSA-2048 keypair, proved possession of the private key (`GET /kiosk/auth/challenge` → sign an RS256 JWS `{aud, nonce, jti, iat}` → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`) → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Check availability** — `POST /kiosk/query {name:"availability", date:"<tomorrow>", party_size:2}` returned the open time-slots that seat two; found the 20:00 2-top. No SQL sent — the AI assistant called an operator-registered named query.
4. **Book the table** — `POST /kiosk/run {name:"book_table", date:"<tomorrow>", time:"20:00", party_size:2}` → HTTP 200, `status:"confirmed"`. The operator atomically claimed the open slot (marking it `booked`) and recorded the booking under the authenticated principal.
5. **Confirm it holds** — `POST /kiosk/query {name:"my_bookings"}` → the one confirmed booking, scoped to this principal alone.

The database confirmed: one row in `bookings` (`status='confirmed'`), the claimed slot marked `booked`.

The business outcome: the user said "book a table for two at Tasca do Tejo tomorrow at 8." Their assistant completed the reservation — discovery, registration, availability, booking — without the user touching anything and without the user having an account at atablefor beforehand.

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

**3. Register named queries**

```ruby
Kiosk::Server::Queries.register("availability") do |args|
  # open slots for args[:date] that seat args[:party_size]
end

Kiosk::Server::Queries.register("my_bookings") do |_params|
  Booking.where("user_id = kiosk.current_user_id()")
end
```

AI assistants call these by name only (`POST /kiosk/query {name:"availability", date:"…", party_size:2}`). They never supply SQL. App-layer isolation lives here: owner-scoped queries filter by `kiosk.current_user_id()` (operator-derived from the session, never an AI-assistant param); the availability catalogue is open to all authenticated AI assistants.

**4. Register Actions (`book_table` and `cancel_booking`)**

```ruby
Kiosk::Server::Actions.register("book_table") do |args|
  uid = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  # atomically claim an open slot matching date/time/party_size, then create
  # a confirmed booking under uid. No payment.
end

Kiosk::Server::Actions.register("cancel_booking") do |args|
  # owner-scoped: WHERE user_id = kiosk.current_user_id() — a cross-principal
  # cancel is a clean 403, and the freed slot returns to availability.
end
```

Actions are plain Ruby blocks. The `kiosk.current_user_id()` Postgres function returns the synthetic principal's ID; the action enforces owner-scope in the block, so an AI assistant cannot cancel or read another principal's booking.

**5. No payment adapter**

There is nothing to wire. atablefor configures no `payment_provider`, so `pay` drops out of the advertised capabilities and the discovery documents carry no payments block. A reservation takes no money — the operator's concern is accountability and anti-scalping, which PoW and reputation handle.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the operator's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal AI assistant that has discovered the `issuer` and `endpoint` via `/.well-known/kiosk.json` can complete a reservation without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic and prices scalping at the door; the anti-bot wall stays in place for everything else.
