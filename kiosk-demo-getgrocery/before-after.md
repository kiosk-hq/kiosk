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

**The differentiator getgrocery adds: substitution negotiation.** Real grocery apps require a human to accept or reject out-of-stock substitutions interactively — typically via in-app push notification at delivery time. No public API surface exposes this decision to agents today. With Kiosk, the agent calls `substitution_options` to discover the suggested substitute, then `apply_substitution` to accept or reject it — no human interaction required, no push notification needed.

**In short:** on real Instacart or Getir, the agent discovers products and deep-links out. The human opens the app, logs in, pays, and later taps a notification to accept or reject substitutions. The agent's contribution is a glorified search result.

---

## With Kiosk — getgrocery (`rake demo` output)

getgrocery is a Rails 8 app that speaks Kiosk. The following is representative output of `rake demo` (from `getgrocery_flow.rb`):

```
{"http_register":201,"http_stores":200,"http_products":200,"http_add_to_cart":200,"http_add_oos":200,"http_sub_options":200,"http_apply_sub":200,"http_delivery_slots":200,"http_confirm_delivery":200,"http_pay":200,"user_id":"a7f3c291-1b2e-4d8a-9cf1-3e507b824f16","agent_id":"b2e94107-3a1c-4f8d-bc2e-91d4a53c7e28","cart_id":"d4f81c3e-7b2a-4e9c-af13-62d7b4c8e509","delivery_id":"e9c2d74f-5a3b-4f8e-b021-73a8c5d9f416","total_cents":2499,"scheduled_at":"2026-06-30T10:00:00.000Z","substitution_accepted":true,"pay":{"ok":true,"kind":"value","value":{"payment_mandate_id":"f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963","psp_reference":"stub_pi_9f4d2c1b-7e3a-4b8f-c219-53d6e8a4b731","settled_amount_cents":2499,"currency":"eur"}}}

── Assertions ──
  OK  http_register == 201
  OK  http_stores == 200
  OK  http_products == 200
  OK  http_add_to_cart == 200
  OK  http_add_oos == 200
  OK  http_sub_options == 200
  OK  http_apply_sub == 200
  OK  http_delivery_slots == 200
  OK  http_confirm_delivery == 200
  OK  http_pay == 200
  OK  delivery_id present (e9c2d74f-5a3b-4f8e-b021-73a8c5d9f416)
  OK  scheduled_at present (2026-06-30T10:00:00.000Z)
  OK  substitution_accepted == true
  OK  pay.ok == true
  OK  pay.value.payment_mandate_id present (f1b3e259-8c4d-4a7f-9e12-84b5c7d2a963)
  OK  deliveries count >= 1 (got 1)
  OK  kiosk.payment_mandates >= 1 (got 1)
  OK  cart_items[substituted=true] >= 1 (got 1)

  All assertions passed.
```

**What the agent did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the getgrocery issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, `POST /kiosk/agents/register {name:"hermes-grocery", public_key:<pem>, role:"customer"}` → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Browse stores** — `POST /kiosk/exec {command:"query", body:{name:"stores"}}` returned FreshMart.
4. **Browse products** — `POST /kiosk/exec {command:"query", body:{name:"products_by_store", store_id:1}}` returned product rows; found organic-milk (in stock) and avocado (out of stock, substitution policy present).
5. **Add in-stock item** — `POST /kiosk/exec {command:"run", body:{name:"add_to_cart", store_id:1, product_id:<milk_id>, qty:2}}` → HTTP 200, `cart_id`, `cart_item_id`.
6. **Add OOS item** — `add_to_cart` again for avocado → HTTP 200, same `cart_id`, new `cart_item_id`.
7. **Query substitution options** — `POST /kiosk/exec {command:"query", body:{name:"substitution_options", product_id:<avocado_id>}}` → returned banana as `suggested_product_id`.
8. **Accept substitution** — `POST /kiosk/exec {command:"run", body:{name:"apply_substitution", cart_id:<cart_id>, cart_item_id:<avocado_item_id>, substitution_product_id:<banana_id>, accept:true}}` → HTTP 200, `accepted:true`. **No human push notification. No in-app prompt. The agent decided.**
9. **Query delivery slots** — `POST /kiosk/exec {command:"query", body:{name:"delivery_slots", date:"2026-06-30"}}` → slot id for 10:00–12:00.
10. **Confirm delivery** — `POST /kiosk/exec {command:"run", body:{name:"confirm_delivery", cart_id:<cart_id>, delivery_slot_id:<slot_id>, delivery_address:"42 Bagdat Caddesi, Istanbul"}}` → HTTP 200, `delivery_id`, `scheduled_at`, `total_cents:2499`.
11. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:2699`, `scope:"grocery"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:2499`, `line_items:[{delivery_id:<delivery_id>, total:2499}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/exec {command:"pay", ...}` → `settled_amount_cents:2499`, `ok:true`.

The database confirmed: one row in `deliveries`, one row in `kiosk.payment_mandates`, one row in `cart_items` with `substituted:true`.

The business outcome: the user said "order groceries from getgrocery." Their assistant completed the purchase — discovery, registration, cart, substitution negotiation, delivery confirmation, payment — without the user touching anything and without the user having an account at getgrocery beforehand.

The provider outcome: getgrocery received a real delivery order and a real payment. The customer relationship stays with getgrocery (the mandate carries the provider's issuer). There is no intermediate platform taking a discovery fee or owning the session.

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

This emits: the Kiosk schema migration (the `kiosk.*` namespace with agents, sessions, and mandate tables), the six-verb wire surface (`query`, `run`, `pay`, `schema`, `help`, `events`) mounted at `/kiosk/exec`, the agent-registration endpoint at `/kiosk/agents/register`, and `/.well-known/kiosk.json`. Today `query`, `run`, and `pay` are wired end-to-end; `schema`, `help`, and `events` are stubbed and ship next.

Agents call named queries by name (`query` verb) — never raw SQL. The provider registers the queries it wishes to expose; isolation is enforced at the app layer in the query definitions and in Actions, with RLS available as optional defense-in-depth.

**3. Register named queries (and optionally apply RLS)**

Register the queries you want to expose to agents:

```ruby
Kiosk::Server::Queries.register("stores") do |_args|
  Store.select(:id, :name, :city)
end

Kiosk::Server::Queries.register("products_by_store") do |args|
  Product.where(store_id: args[:store_id])
    .select(:id, :name, :sku, :price_cents, :stock, :substitution_policy)
end

Kiosk::Server::Queries.register("substitution_options") do |args|
  SubstitutionPolicy.where(product_id: args[:product_id])
    .select(:product_id, :suggested_product_id)
end

Kiosk::Server::Queries.register("delivery_slots") do |args|
  DeliverySlot.where(date: args[:date], available: true)
    .select(:id, :date, :label, :start_time, :end_time)
end

Kiosk::Server::Queries.register("my_orders") do |_args|
  Delivery.where("user_id = kiosk.current_user_id()")
    .select(:id, :status, :scheduled_at, :total_cents, :delivery_address)
end
```

The handler block receives only the agent-supplied params and runs inside a session whose `kiosk.current_user_id()` is the authenticated principal. `my_orders` scopes by `kiosk.current_user_id()` (server-derived from the session, never an agent param). Catalogue queries are open to all authenticated agents.

RLS is available as optional defense-in-depth via `enable_rls_on` — useful if you want a Postgres-level backstop in addition to the app-layer checks. It is not required for Kiosk's isolation model.

**4. Register Actions (with ownership checks)**

`apply_substitution` and `confirm_delivery` are **ownership-gated** — the server must verify `WHERE id = cart_id AND user_id = kiosk.current_user_id()` before mutating. Register them with an ownership check block:

```ruby
Kiosk::Server::Actions.register("add_to_cart") do |args|
  uid  = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  cart = Cart.find_or_create_by!(user_id: uid, store_id: args[:store_id])
  item = cart.cart_items.create!(product_id: args[:product_id], qty: args[:qty])
  { cart_id: cart.id, cart_item_id: item.id, store_id: cart.store_id, product_id: item.product_id, qty: item.qty }
end

Kiosk::Server::Actions.register("apply_substitution") do |args|
  uid  = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  cart = Cart.find_by!("id = ? AND user_id = ?", args[:cart_id], uid)  # ownership gate → 404/403 if not owner
  item = cart.cart_items.find(args[:cart_item_id])
  if args[:accept]
    item.update!(substitution_product_id: args[:substitution_product_id], substituted: true)
  else
    item.destroy!
  end
  { cart_item_id: item.id, accepted: args[:accept] }
end

Kiosk::Server::Actions.register("confirm_delivery") do |args|
  uid      = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  cart     = Cart.find_by!("id = ? AND user_id = ?", args[:cart_id], uid)  # ownership gate → 404/403 if not owner
  slot     = DeliverySlot.find(args[:delivery_slot_id])
  delivery = Delivery.create!(
    user_id:          uid,
    cart_id:          cart.id,
    delivery_slot_id: slot.id,
    delivery_address: args.fetch(:delivery_address),
    total_cents:      cart.cart_items.sum { |i| i.effective_price_cents * i.qty },
    scheduled_at:     slot.start_time,
  )
  { delivery_id: delivery.id, scheduled_at: delivery.scheduled_at, total_cents: delivery.total_cents, status: delivery.status }
end
```

**5. Wire a payment-provider adapter**

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer           = "https://getgrocery.app"
  c.payment_provider = KioskPay::Stripe::Adapter.new(secret_key: ENV["STRIPE_SECRET_KEY"])
end
```

The stub PSP (`StubPsp`) used in the demo can be swapped for the Stripe adapter without touching any other code.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the provider's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal agent that has read `KIOSK.skill.md` — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a grocery order including substitution negotiation without the user having an account at the provider and without the user being present. The provider drops its anti-bot wall for sanctioned agent traffic; the anti-bot wall stays in place for everything else.

See `getgrocery_flow.rb` in this directory for the full worked example.

---

*Validation research source: `docs/research/2026-06-22-consumer-agent-validation.md` — primary evidence from live connector probes (Uber Eats, Booking.com) plus independent verification of OpenAI Instant Checkout walkback, Amazon v. Perplexity injunction, and Google Universal Cart, all as of 2026-06-22.*
