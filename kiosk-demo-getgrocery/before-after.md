# Before and After — why agents stall at Instacart and Getir, and what getgrocery proves

**Honesty note up front.** getgrocery is what Instacart/Getir would look like if it spoke Kiosk — a fake-but-realistic grocery-delivery provider built to demonstrate the mechanism. Nothing below implies that real Instacart or Getir work this way. The demo proves the *mechanism* works; whether providers will adopt it is an open question.

---

## Before — a real agent on real Instacart or Getir today

Every current personal agent (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same walls: the anti-bot screen, the login gate, and — uniquely in grocery — the substitution confirmation wall.

**Anti-bot friction documented in validation research** (`docs/research/2026-06-22-consumer-agent-validation.md`, Front B):

> Documented ChatGPT-Agent food orders take **6–20 minutes** (2–3× human) and stop at the **anti-bot screen, login, or payment** — the agent opens a user browser to finish.

The structural root cause is a stack of incompatible requirements: behavioral fingerprinting (Cloudflare Turnstile, DataDome) flags agent traffic; OTP walls assume a human-held device; the user's payment instrument lives outside the agent's context; and EU/UK PSD2 SCA requires a biometric or device-OTP challenge on first use that only the human can satisfy.

**Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) stop at discovery** (`docs/research/2026-06-22-consumer-agent-validation.md`, Front A):

> Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) **stop at discovery.** Their terminal step is a deep link back to the provider's own app/site, where the human must register and pay.

The complete Uber Eats tool surface available to Claude has two tools: `search` (returns restaurant listings) and `publish_analytics` (internal telemetry). The session schema's own `deeplink_id` field is described as *"Id generated in the widget before navigating to Uber Eats"* — confirming the intended flow: **the agent shows options, then deep-links the user out to the Uber Eats app** to register, pay, and order. There is no add-to-cart, checkout, payment, or confirm tool.

**The same pattern holds for grocery platforms (Instacart, Getir):** both expose search and deep-link flows but no add-to-cart, checkout, substitution acceptance, or payment API. The agent shows available groceries, then hands the user to the app.

The reason incumbents stay at discovery is economic, not technical. Grocery retail media — Instacart ads $1.18B FY2024 (SEC filing, cited in `docs/research/2026-06-22-consumer-agent-validation.md`, Front C) — requires an authenticated in-app session for sponsored placement and closed-loop attribution. A silent agent order via a structured API erases that ad surface entirely. The discovery funnel *is* the product.

**The differentiator getgrocery adds:** The provider's catalog returns facts only — in-stock items. Out-of-stock items are simply absent. The AI assistant reasons over the catalog to resolve substitutions before calling `create_order`. Real grocery apps require a human to accept substitutions via push notification. With Kiosk, the assistant handles substitution decisions using the catalog, without any provider-side substitution surface or human push notification.

**In short:** on real Instacart or Getir, the agent discovers products and deep-links out. The human opens the app, logs in, pays, and later taps a notification to accept or reject substitutions. The agent's contribution is a glorified search result.

---

## With Kiosk — getgrocery (`rake demo` output)

getgrocery is a Rails 8 app that speaks Kiosk. The following is representative output of `rake demo` (from `getgrocery_flow.rb`):

```
{"http_register":201,"http_catalog":200,"http_order":200,"http_slots":200,"http_pay":200,"http_schedule":200,"http_my_orders":200,"user_id":"a7f3c291-1b2e-4d8a-9cf1-3e507b824f16","agent_id":"b2e94107-3a1c-4f8d-bc2e-91d4a53c7e28","order_id":"d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509","total_cents":2499,"scheduled_at":"2026-06-30T10:00:00.000Z","pay":{"ok":true,"kind":"value","value":{"payment_mandate_id":"f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963","psp_reference":"stub_pi_9f4d2c1b-7e3a-4b8f-c219-53d6e8a4b731","settled_amount_cents":2499,"currency":"eur"}}}

── Assertions ──
  OK  http_register == 201
  OK  http_catalog == 200
  OK  http_order == 200
  OK  http_slots == 200
  OK  http_pay == 200
  OK  http_schedule == 200
  OK  http_my_orders == 200
  OK  order_id present (d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509)
  OK  scheduled_at present (2026-06-30T10:00:00.000Z)
  OK  pay.ok == true
  OK  pay.value.payment_mandate_id present (f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963)
  OK  orders count >= 1 (got 1)
  OK  kiosk.payment_mandates >= 1 (got 1)

  All assertions passed.
```

**What the agent did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the GetGroceries issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, proved possession of the private key (`GET /kiosk/auth/challenge` → signed the nonce as an origin-bound RS256 JWS → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`) → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Browse catalog** — `POST /kiosk/query {name:"catalog"}` returned 15 in-stock products. Milk 1 L and Chocolate Spread 400g were absent (out of stock) — the assistant resolved these before building the order: substituted Milk 1 L with 2× Milk 0.5 L, omitted Chocolate Spread after confirming with the user.
4. **Create order** — `POST /kiosk/run {name:"create_order", items:[{sku:"milk-0.5l", qty:2}, {sku:"free-range-eggs", qty:1}]}` → HTTP 200, `order_id`, `total_cents:2499`. The assistant composed the full cart (products referenced by `sku`); substitution was handled before this call, not after.
5. **Query delivery slots** — `POST /kiosk/query {name:"delivery_slots", date:"2026-06-30"}` → returned 6 available time slots; assistant picked 10:00–12:00.
6. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:2699`, `scope:"grocery"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:2499`, `line_items:[{order_id:<order_id>, total:2499}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws, cart_mandate_jws, payment_mandate_jws}` → `settled_amount_cents:2499`, `ok:true`.
7. **Schedule delivery** — `POST /kiosk/run {name:"schedule_delivery", order_id:<order_id>, delivery_slot_id:<slot_id>, delivery_address:"42 Sakura Lane, Neo-Tokyo"}` → HTTP 200, `scheduled_at:"2026-06-30T10:00:00.000Z"`.

The database confirmed: one row in `orders` with `status='scheduled'`, one row in `kiosk.payment_mandates`.

The business outcome: the user said "order groceries from GetGroceries." Their assistant completed the purchase — discovery, registration, catalog browse, substitution reasoning, order creation, payment, delivery scheduling — without the user touching anything and without the user having an account at GetGroceries beforehand.

The provider outcome: GetGroceries received a real order and a real payment. The customer relationship stays with GetGroceries (the mandate carries the provider's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake provider with a stub payment processor.** The mechanism works. Whether real providers will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the provider adoption recipe

The delta between "today's Instacart" and "getgrocery" is a provider-side integration. The pieces:

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

This emits: the Kiosk schema migration (the `kiosk.*` namespace with agents, sessions, and mandate tables), the REST wire surface (`GET /kiosk/schema`, `POST /kiosk/query`, `POST /kiosk/run`, `POST /kiosk/pay`), the auth handshake at `/kiosk/auth/{challenge,register,login,revoke}`, and `/.well-known/kiosk.json`. Today `query`, `run`, `pay`, and `schema` are wired end-to-end (agent self-discovery works — see `rake demo:schema`); `events` is stubbed and ships next.

Agents call named queries by name (`query` verb) — never raw SQL. The provider registers the queries it wishes to expose; isolation is enforced at the app layer in the query definitions and in Actions, with RLS available as optional defense-in-depth.

**3. Register named queries (and optionally apply RLS)**

Register the queries you want to expose to agents:

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

The handler block receives only the agent-supplied params and runs inside a session whose `kiosk.current_user_id()` is the authenticated principal. `my_orders` scopes by `kiosk.current_user_id()` (server-derived from the session, never an agent param). Catalogue queries are open to all authenticated agents.

RLS is available as optional defense-in-depth via `enable_rls_on` — useful if you want a Postgres-level backstop in addition to the app-layer checks. It is not required for Kiosk's isolation model.

**4. Register Actions (with ownership checks)**

`schedule_delivery` is **payment-binding gated** — the server must verify a settled mandate exists for the order before mutating. `create_order` attaches ownership via `kiosk.current_user_id()`. Register them:

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

Kiosk::Server::Actions.register("schedule_delivery") do |args|
  uid  = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  # Payment-binding gate: verify a settled mandate references this order
  paid = ActiveRecord::Base.connection.execute(<<~SQL).first["paid"]
    SELECT EXISTS (
      SELECT 1 FROM kiosk.cart_mandates cm
      JOIN kiosk.payment_mandates pm ON pm.cart_mandate_id = cm.id
      WHERE cm.line_items @> json_build_array(
        json_build_object('order_id', #{ActiveRecord::Base.connection.quote(args[:order_id])})
      )::jsonb
    ) AS paid
  SQL
  raise Kiosk::PaymentRequired, "order must be paid before scheduling" unless paid == "t" || paid == true

  order = Order.find_by!("id = ? AND user_id = ?", args[:order_id], uid)
  slot  = DeliverySlot.find(args[:delivery_slot_id])
  order.update!(
    status:   "scheduled",
    slot_at:  slot.start_time,
    address:  args.fetch(:delivery_address),
  )
  { order_id: order.id, scheduled_at: order.slot_at, status: order.status }
end
```

**5. Wire a payment-provider adapter**

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer           = "https://getgroceries.app"
  c.payment_provider = KioskPay::Stripe::Adapter.new(secret_key: ENV["STRIPE_SECRET_KEY"])
end
```

This demo uses the **real Stripe adapter in test mode** (`STRIPE_SECRET_KEY=sk_test_…`): the buyer's card is saved once via a hosted SetupIntent and charged `off_session` per purchase — the assistant never holds card data. See `docs/architecture/payment-model.md`.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the provider's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal agent that has read `KIOSK.skill.md` — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a grocery order without the user having an account at the provider and without the user being present. The provider drops its anti-bot wall for sanctioned agent traffic; the anti-bot wall stays in place for everything else.

See `getgrocery_flow.rb` in this directory for the full worked example.

---

*Validation research source: `docs/research/2026-06-22-consumer-agent-validation.md` — primary evidence from live connector probes (Uber Eats, Booking.com) plus independent verification of OpenAI Instant Checkout walkback, Amazon v. Perplexity injunction, and Google Universal Cart, all as of 2026-06-22.*
