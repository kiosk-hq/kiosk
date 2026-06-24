# Before and After — why agents stall at Wolt, and what foodelivery proves

**Honesty note up front.** foodelivery is what Wolt *would* look like if it spoke Kiosk — a fake-but-realistic food-delivery provider built to demonstrate the mechanism. Nothing below implies that real Wolt works this way. The demo proves the *mechanism* works; whether providers will adopt it is an open question.

---

## Before — a real agent on real Wolt today

Every current personal agent (Hermes, OpenClaw, ChatGPT Agent, Gemini with app navigation) stalls at the same two walls: the anti-bot screen and the login/payment gate.

**Anti-bot friction documented in validation research** (`docs/research/2026-06-22-consumer-agent-validation.md`, Front B):

> Documented ChatGPT-Agent food orders take **6–20 minutes** (2–3× human) and stop at the **anti-bot screen, login, or payment** — the agent opens a user browser to finish.

The structural root cause is a stack of incompatible requirements: behavioral fingerprinting (Cloudflare Turnstile, DataDome) flags agent traffic; OTP walls assume a human-held device; the user's payment instrument lives outside the agent's context; and EU/UK PSD2 SCA requires a biometric or device-OTP challenge on first use that only the human can satisfy.

**The Uber Eats connector probed in-session confirms the end-state** (`docs/research/2026-06-22-consumer-agent-validation.md`, Front A):

The complete Uber Eats tool surface available to Claude has two tools: `search` (returns restaurant listings) and `publish_analytics` (internal telemetry). The session schema's own `deeplink_id` field is described as *"Id generated in the widget before navigating to Uber Eats"* — confirming the intended flow: **the agent shows options, then deep-links the user out to the Uber Eats app** to register, pay, and order. There is no add-to-cart, checkout, payment, or confirm tool.

**The same pattern holds across every platform verified** (Front A, Front E, Front F):

> Both flagship consumer-commerce connectors in Claude today (Uber Eats, Booking.com) **stop at discovery.** Their terminal step is a deep link back to the provider's own app/site, where the human must register and pay.

The reason incumbents stay at discovery is economic, not technical. Food-delivery retail media (Uber ads at ~$2B annualized run-rate; DoorDash ad revenue substantially over $100M/yr; Instacart ads $1.18B FY2024) requires an authenticated in-app session for sponsored placement and closed-loop attribution. A silent agent order via a structured API erases that ad surface entirely. The discovery funnel *is* the product. (Front C, SEC filings cited in validation doc.)

**OpenAI's attempt confirms the obstacle.** OpenAI launched "Instant Checkout" (with Stripe, Shopify, Etsy) on 29 September 2025, then walked it back around 5–6 March 2026 after roughly six months: ~12–30 Shopify merchants ever live; users were high-intent browsers who did not convert; merchants refused to cede checkout; no US sales-tax remittance; scraping gave inaccurate stock, price, and shipping data. OpenAI pivoted to discovery + merchant-controlled apps. (Front C — independently re-verified 2026-06-22.)

The lesson the validation doc draws:

> Even OpenAI+Stripe+Shopify couldn't make generic, scraped in-chat checkout stick — precisely because they tried it **without first-class merchant cooperation.** That validates the **problem** a provider-side, merchant-sanctioned standard targets.

**In short:** the agent discovers where to order, then hands back to the human. The human registers, passes bot checks, authenticates, and pays. The agent's contribution is a glorified search result.

---

## With Kiosk — foodelivery (`rake demo` output)

foodelivery is a Rails 8.1 app that speaks Kiosk. The following is the recorded output of two consecutive `rake demo` runs (from `oss/.superpowers/sdd/plan3-BC-report.md`, commit 999f28b).

**Run 1:**
```
{"http_register":201,"user_id":"3e406ba4-46a0-402d-a5c1-7eadb173db82","agent_id":"e118679e-009e-4458-8bbd-573ccfe0985a","order":{"order_id":"18aaacf8-1e7e-484c-b02d-76f578854418","restaurant_id":1,"total_cents":1599,"status":"placed"},"pay":{"ok":true,"kind":"value","value":{"payment_mandate_id":"4ae8407f-451d-46ca-8869-0c8e8d337719","psp_reference":"stub_pi_8380d66b-5a24-4cf4-9d0f-06b8c9464a64","settled_amount_cents":1599,"currency":"eur"}}}

── Assertions ──
  ✓  pay.ok == true
  ✓  pay.value.payment_mandate_id present (4ae8407f-451d-46ca-8869-0c8e8d337719)
  ✓  order.order_id present (18aaacf8-1e7e-484c-b02d-76f578854418)
  ✓  orders count = 1
  ✓  kiosk.payment_mandates count = 1

  All assertions passed.
```

**What the agent did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the foodelivery issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, `POST /kiosk/agents/register {name:"hermes", public_key:<pem>, role:"customer"}` → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Browse** — `POST /kiosk/exec {command:"sql", ...}` queried `menu_items JOIN restaurants` and found the Margherita: `id`, `sku:"margherita"`, `price_cents:1599`.
4. **Place order** — `POST /kiosk/exec {command:"run", body:{name:"place_order", menu_item_id:<id>, quantity:1, delivery_address:"1 Test St, Istanbul"}}` → HTTP 200, `total_cents:1599`, `status:"placed"`.
5. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:1699`, `scope:"food"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:1599`, `line_items:[{sku:"margherita",qty:1}]`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/exec {command:"pay", ...}` → `settled_amount_cents:1599`, `ok:true`.

The database confirmed: one row in `orders`, one row in `kiosk.payment_mandates`.

The business outcome: the user said "order a Margherita from foodelivery." Their assistant completed the purchase — discovery, registration, order, payment — without the user touching anything and without the user having an account at foodelivery beforehand.

The provider outcome: foodelivery received a real order and a real payment. The customer relationship stays with foodelivery (the mandate carries the provider's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake provider with a stub payment processor.** The mechanism works. Whether real providers will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the provider adoption recipe

The delta between "today's Wolt" and "foodelivery" is a provider-side integration. The pieces:

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

This emits: the Kiosk schema migration (the `kiosk.*` namespace with agents, sessions, and mandate tables), the six-verb wire surface (`sql`, `run`, `pay`, `schema`, `help`, `events`) mounted at `/kiosk/exec`, the agent-registration endpoint at `/kiosk/agents/register`, and `/.well-known/kiosk.json`. Today `sql`, `run`, and `pay` are wired end-to-end; `schema`, `help`, and `events` are stubbed and ship next.

**3. Apply RLS to your own tables**

In your migration, declare which tables agents can read or write and under what conditions:

```ruby
enable_rls_on :orders do
  policy :select, using: "user_id = kiosk.current_user_id()"
  policy :insert, check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
end
```

Catalogue tables (restaurants, menu items) get `policy :select, using: "TRUE"`. The provider controls exactly what each agent role can see and do.

**4. Register a `place_order` Action**

```ruby
Kiosk::Server::Actions.register("place_order") do |args|
  uid  = ActiveRecord::Base.connection.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  item = MenuItem.find(args[:menu_item_id])
  qty  = (args[:quantity] || 1).to_i
  order = Order.create!(
    user_id:          uid,
    restaurant_id:    item.restaurant_id,
    menu_item_id:     item.id,
    quantity:         qty,
    total_cents:      item.price_cents * qty,
    delivery_address: args.fetch(:delivery_address),
  )
  { order_id: order.id, total_cents: order.total_cents, status: order.status }
end
```

Actions are plain Ruby blocks. The `kiosk.current_user_id()` Postgres function returns the synthetic principal's ID, enforced by the same RLS that governs direct queries. The action cannot access rows belonging to other users.

**5. Wire a payment-provider adapter**

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer           = "https://foodelivery.app"
  c.payment_provider = KioskPay::Stripe::Adapter.new(secret_key: ENV["STRIPE_SECRET_KEY"])
end
```

The stub PSP (`StubPsp`) used in the demo can be swapped for the Stripe adapter without touching any other code.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or any changes to the provider's existing Rails models. The satellite gems add a parallel surface; the existing application is untouched.

**What this enables:** any personal agent that has read `KIOSK.skill.md` — or that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` — can complete a purchase without the user having an account at the provider and without the user being present. The provider drops its anti-bot wall for sanctioned agent traffic; the anti-bot wall stays in place for everything else.

---

*Validation research source: `docs/research/2026-06-22-consumer-agent-validation.md` — primary evidence from live connector probes (Uber Eats, Booking.com) plus independent verification of OpenAI Instant Checkout walkback, Amazon v. Perplexity injunction, and Google Universal Cart, all as of 2026-06-22.*
