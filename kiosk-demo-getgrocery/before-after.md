# Before and After — why AI assistants stall at Instacart and Getir, and what getgrocery proves

**Honesty note up front.** getgrocery is what Instacart/Getir would look like if it spoke Kiosk — a fake-but-realistic grocery-delivery operator built to demonstrate the mechanism. Nothing below implies that real Instacart or Getir work this way. The demo proves the *mechanism* works; whether operators will adopt it is an open question.

---

## Before — a real AI assistant on real Instacart or Getir today

Every current personal AI assistant (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same walls: the anti-bot screen, the login gate, and — uniquely in grocery — the substitution confirmation wall.

**Anti-bot friction documented in validation research:**

> Documented ChatGPT-Agent food orders take **6–20 minutes** (2–3× human) and stop at the **anti-bot screen, login, or payment** — the AI assistant opens a user browser to finish.

The structural root cause is a stack of incompatible requirements: behavioral fingerprinting (Cloudflare Turnstile, DataDome) flags AI-assistant traffic; OTP walls assume a human-held device; the user's payment instrument lives outside the AI assistant's context; and EU/UK PSD2 SCA requires a biometric or device-OTP challenge on first use that only the human can satisfy.

**Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) stop at discovery:**

> Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) **stop at discovery.** Their terminal step is a deep link back to the operator's own app/site, where the human must register and pay.

The complete Uber Eats tool surface available to Claude has two tools: `search` (returns restaurant listings) and `publish_analytics` (internal telemetry). The session schema's own `deeplink_id` field is described as *"Id generated in the widget before navigating to Uber Eats"* — confirming the intended flow: **the AI assistant shows options, then deep-links the user out to the Uber Eats app** to register, pay, and order. There is no add-to-cart, checkout, payment, or confirm tool.

**The same pattern holds for grocery platforms (Instacart, Getir):** both expose search and deep-link flows but no add-to-cart, checkout, substitution acceptance, or payment API. The AI assistant shows available groceries, then hands the user to the app.

The reason incumbents stay at discovery is economic, not technical. Grocery retail media — Instacart ads $1.18B FY2024 (SEC filing) — requires an authenticated in-app session for sponsored placement and closed-loop attribution. A silent AI-assistant order via a structured API erases that ad surface entirely. The discovery funnel *is* the product.

**The differentiator getgrocery adds:** The operator's catalog returns facts only — in-stock items. Out-of-stock items are simply absent. The AI assistant reasons over the catalog to resolve substitutions before calling `create_order`. Real grocery apps require a human to accept substitutions via push notification. With Kiosk, the assistant handles substitution decisions using the catalog, without any operator-side substitution surface or human push notification.

**In short:** on real Instacart or Getir, the AI assistant discovers products and deep-links out. The human opens the app, logs in, pays, and later taps a notification to accept or reject substitutions. The AI assistant's contribution is a glorified search result.

---

## With Kiosk — getgrocery (`rake demo` output)

getgrocery is a Rails 8 app that speaks Kiosk. The following is representative output of `rake demo` (from `script/getgrocery_flow.rb`), run against the real Stripe adapter in test mode — `psp_reference` is a genuine Stripe test-mode `pi_…` PaymentIntent and settlement is recorded in `kiosk.settlements`:

```
{"http_register":201,"http_catalog":200,"http_order":200,"http_slots":200,"http_payment_setup":200,"http_pay":200,"http_schedule":200,"http_my_orders":200,"user_id":"a7f3c291-1b2e-4d8a-9cf1-3e507b824f16","agent_id":"b2e94107-3a1c-4f8d-bc2e-91d4a53c7e28","order_id":"d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509","total_cents":847,"scheduled_at":"2026-07-13T08:00:00.000Z","psp_reference":"pi_3Qk9fLR2bkGb2V0T1aX7dZ8p","pay":{"ok":true,"kind":"value","value":{"settlement_id":"f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963","psp_reference":"pi_3Qk9fLR2bkGb2V0T1aX7dZ8p","settled_amount_cents":847,"currency":"eur"}}}

-- Assertions --
  OK  http_register == 201
  OK  http_catalog == 200
  OK  http_order == 200
  OK  http_slots == 200
  OK  http_payment_setup == 200
  OK  http_pay == 200
  OK  http_schedule == 200
  OK  http_my_orders == 200
  OK  order_id present (d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509)
  OK  scheduled_at present (2026-07-13T08:00:00.000Z)
  OK  pay.ok == true
  OK  pay.value.settlement_id present (f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963)
  OK  psp_reference is a real Stripe PaymentIntent (pi_3Qk9fLR2bkGb2V0T1aX7dZ8p)
  OK  orders[status=scheduled] count >= 1 (got 1)
  OK  kiosk.settlements >= 1 (got 1)
  OK  order_items count >= 1 (got 3)
  OK  my_orders contains own order d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509

  All assertions passed.
```

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the GetGrocery issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, proved possession of the private key (`GET /kiosk/auth/challenge` → signed the nonce as an origin-bound RS256 JWS → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`) → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Browse catalog** — `POST /kiosk/query {name:"catalog"}` returned 15 in-stock products, sorted by name (Milk 1 L and Chocolate Spread 400g are out of stock, so the catalog hides them — see `db/seeds.rb`). This worked example's driver builds the cart from the first three in-stock rows: Apple Juice (349c), Banana (149c), Butter 250g (349c), one of each.
4. **Query delivery slots** — `POST /kiosk/query {name:"delivery_slots", date:"2026-07-13"}` → returned 6 available time slots; the driver picked the first, 08:00–10:00.
5. **Create order** — `POST /kiosk/run {name:"create_order", items:[{sku:"apple-juice", qty:1}, {sku:"banana", qty:1}, {sku:"butter-250g", qty:1}], delivery_slot_id:<slot_id>, delivery_address:"42 Camden Street, Dublin 2"}` → HTTP 200, `order_id`, `total_cents:847`, `slot_at`, and a `pay_hint`. Delivery is part of the order — slot and address are REQUIRED; the assistant composed the full cart (products referenced by `sku`).
6. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:1047`, `scope:"grocery"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:847`, `line_items:[{order_id:<order_id>}, {sku:"apple-juice", qty:1, price_cents:349}, {sku:"banana", qty:1, price_cents:149}, {sku:"butter-250g", qty:1, price_cents:349}]` — mirroring the order per the `pay_hint`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws, cart_mandate_jws, payment_mandate_jws}` → `settled_amount_cents:847`, `ok:true`.
7. **(Optional) Move the delivery** — a PAID order's slot can be changed once via `POST /kiosk/run {name:"reschedule_delivery", order_id:<order_id>, delivery_slot_id:<new_slot_id>}`. The operator's cashier check ran at capture: currency (EUR), each line against the catalog, and the total were verified before charging.

The database confirmed: one row in `orders` with its delivery slot set (`slot_at`), one row in `kiosk.settlements`.

The business outcome: the user said "order groceries from GetGrocery." Their assistant completed the purchase — discovery, registration, catalog browse, order creation (delivery booked as part of the order), payment — without the user touching anything and without the user having an account at GetGrocery beforehand.

The operator outcome: GetGrocery received a real order and a real payment. The customer relationship stays with GetGrocery (the mandate carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator, settled through the real Stripe adapter in test mode.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the operator adoption recipe

The delta between "today's Instacart" and "getgrocery" is an operator-side integration. The pieces:

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
# REST endpoints: one per verb, HTTP method carries the semantics.
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

`query`, `run`, `pay`, and `schema` are wired end-to-end (AI-assistant self-discovery works — see `rake demo:schema`). (A follow-up release will mount these via the engine's own routes drawer so this block collapses to one line.)

AI assistants call named queries by name (`query` verb) — never raw SQL. The operator registers the queries it wishes to expose; isolation is enforced at the app layer in the query definitions and in Actions, with RLS available as optional defense-in-depth.

**3. Register named queries (and optionally apply RLS)**

Register the queries you want to expose to AI assistants:

```ruby
Kiosk::Server::Queries.register("catalog") do |_args|
  Product.where("stock > 0")
    .select(:id, :name, :price_cents)
end

Kiosk::Server::Queries.register("delivery_slots") do |args|
  DeliverySlot.where(date: args[:date], available: true)
    .select(:id, :date, :label, :start_time, :end_time)
end

Kiosk::Server::Queries.register("my_orders") do |_args|
  Order.where("user_id = kiosk.current_user_id()")
    .select(:id, :status, :total_cents, :slot_at, :address, :created_at)
end
```

The handler block receives only the AI-assistant-supplied params and runs inside a session whose `kiosk.current_user_id()` is the authenticated principal. `my_orders` scopes by `kiosk.current_user_id()` (server-derived from the session, never an AI-assistant param). Catalogue queries are open to all authenticated AI assistants.

RLS is available as optional defense-in-depth via `enable_rls_on` — useful if you want a Postgres-level backstop in addition to the app-layer checks. It is not required for Kiosk's isolation model.

**4. Register Actions (with ownership checks)**

`reschedule_delivery` is **payment-binding gated** — the server must verify a settled mandate exists for the order before mutating. `create_order` attaches ownership via `kiosk.current_user_id()` and requires the delivery slot + address up front (delivery is part of the order). Register them:

```ruby
Kiosk::Server::Actions.register("create_order") do |args|
  uid   = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  order = Order.create!(user_id: uid, status: "created")
  args[:items].each do |item|
    product = Product.find_by!(sku: item[:sku])   # agents reference products by sku
    order.order_items.create!(product: product, qty: item[:qty])
  end
  order.update!(total_cents: order.order_items.sum { |i| i.product.price_cents * i.qty })
  { order_id: order.id, total_cents: order.total_cents, status: order.status }
end

Kiosk::Server::Actions.register("reschedule_delivery") do |args|
  uid  = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  # Payment-binding gate: verify a settlement (capture receipt) references this order
  paid = ActiveRecord::Base.connection.execute(<<~SQL).first["paid"]
    SELECT EXISTS (
      SELECT 1 FROM kiosk.settlements pm
      JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id
      WHERE cm.line_items @> json_build_array(
        json_build_object('order_id', #{ActiveRecord::Base.connection.quote(args[:order_id])})
      )::jsonb
    ) AS paid
  SQL
  raise Kiosk::Server::Errors::Forbidden, "no settlement for this order" unless paid == "t" || paid == true

  order = Order.find_by!("id = ? AND user_id = ?", args[:order_id], uid)
  slot  = DeliverySlot.find(args[:delivery_slot_id])
  order.update!(
    status:   "rescheduled",
    slot_at:  slot.start_time,
  )
  { order_id: order.id, rescheduled_at: order.slot_at, status: order.status }
end
```

**5. Wire a payment-provider adapter**

```ruby
# config/environments/production.rb — ENV is read per environment, once
config.x.kiosk.stripe_secret_key = ENV["STRIPE_SECRET_KEY"].presence

# config/initializers/kiosk.rb — the initializer reads the resolved value
Kiosk.configure do |c|
  c.issuer           = Rails.configuration.x.kiosk.issuer
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key: Rails.configuration.x.kiosk.stripe_secret_key,
  )
end
```

This demo uses the **real Stripe adapter in test mode** (`STRIPE_SECRET_KEY=sk_test_…`): the buyer's card is saved once via a hosted SetupIntent and charged `off_session` per purchase — the assistant never holds card data.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the operator's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal AI assistant that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` and reads the served surface via `GET /kiosk/schema` (see `rake demo:schema`) can complete a grocery order without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic; the anti-bot wall stays in place for everything else.

See `script/getgrocery_flow.rb` in this directory for the full worked example.

---

*Validation research: primary evidence from live connector probes (Uber Eats, Booking.com) plus independent verification of OpenAI Instant Checkout walkback, Amazon v. Perplexity injunction, and Google Universal Cart, all as of 2026-06-22.*
