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

getgrocery is a Rails 8 app that speaks Kiosk. Below is the **verbatim** output
of `rake demo` (which runs `script/getgrocery_flow.rb`) — recorded
**2026-08-20** against a booted demo, `demo:setup`'s database chatter removed
and nothing else touched.

**This recording is the secret-free path**, the one CI runs: with no
`STRIPE_SECRET_KEY` in the environment the task starts a local `stripe-mock`,
so `psp_reference` is a `stripe-mock` PaymentIntent and `settled_amount_cents`
is that fixture's constant `0` — which is why the run declines to assert the
settled amount and says so in an assertion of its own. Set a real `sk_test_…`
and the identical flow charges Stripe test mode instead; the task prefers a real
key whenever one is present.

```
  (no STRIPE_SECRET_KEY — running against stripe-mock at http://127.0.0.1:12111, no real charge)
  (add to /etc/hosts: 127.0.0.1 getgrocery.demo.kiosk.tech -- using 127.0.0.1)

-- Starting getgrocery on http://127.0.0.1:3001 --
  Server up at http://127.0.0.1:3001

-- Running script/getgrocery_flow.rb --
  Registered: user_id=4bcb25af-7193-4f05-a3c7-6df64c4948be
  Catalog: 16 in-stock products (EUR)
  Ordering: sku=apple-juice, sku=banana, sku=butter-250g
  delivery_slots (district-less address): http=400 code=bad_request (rejected, as expected)
  Delivery slot: id=6 18:00–20:00 zone=D02 on 2026-08-20 (2026-08-20T18:00:00+01:00)
  K-480: create_order on past slot id=1 → http=400 code=bad_request (rejected, as expected)
  create_order: order_id=1dba3640-c454-499a-b7ed-9b11193a856d total=€8.47 slot_at=2026-08-20T18:00:00+01:00
  payment_setup: ready
  pay: settlement_id=95bbacf6-9c43-4163-8ae8-782bdc2af24f psp_reference=pi_RE3z1qccCW0HNt1
  my_orders: 1 order(s); own order paid=true
{"http_register":201,"http_catalog":200,"http_slots":200,"http_slots_badzone":400,"slots_badzone_code":"bad_request","http_order":200,"http_payment_setup":200,"http_pay":200,"http_my_orders":200,"user_id":"4bcb25af-7193-4f05-a3c7-6df64c4948be","agent_id":"d835cfcc-c559-4887-a23e-fcf401ea18e5","order_id":"1dba3640-c454-499a-b7ed-9b11193a856d","total_cents":847,"slot_at":"2026-08-20T18:00:00+01:00","chosen_slot_at":"2026-08-20T18:00:00+01:00","slot_date":"2026-08-20","past_slot_check":{"id":1,"http":400,"code":"bad_request"},"paid":true,"psp_reference":"pi_RE3z1qccCW0HNt1","my_orders":[{"order_id":"1dba3640-c454-499a-b7ed-9b11193a856d","status":"paid","total_cents":847,"slot_at":"2026-08-20T17:00:00.000+00:00","address":"42 Camden Street, Dublin 2","paid":true}],"pay":{"settlement_id":"95bbacf6-9c43-4163-8ae8-782bdc2af24f","psp_reference":"pi_RE3z1qccCW0HNt1","settled_amount_cents":0,"currency":"eur"}}

-- Assertions --
  OK  http_register == 201
  OK  http_catalog == 200
  OK  http_order == 200
  OK  http_slots == 200
  OK  http_slots_badzone == 400
  OK  slots_badzone_code == bad_request
  OK  http_payment_setup == 200
  OK  http_pay == 200
  OK  http_my_orders == 200
  OK  order_id present (1dba3640-c454-499a-b7ed-9b11193a856d)
  OK  slot_at present (2026-08-20T18:00:00+01:00)
  OK  create_order slot_at == chosen delivery_slot slot_at (2026-08-20T18:00:00+01:00) — no date drift
  OK  K-480: create_order on past slot id=1 → 400 bad_request (un-bookable window rejected)
  OK  my_orders own order paid == true
  OK  pay.settlement_id present (95bbacf6-9c43-4163-8ae8-782bdc2af24f)
  OK  pay.psp_reference present (pi_RE3z1qccCW0HNt1)
  OK  pay.settled_amount_cents present (0)
  OK  pay.currency present (eur)
  OK  the settlement is denominated in the operator's own currency (eur)
  OK  (settled amount not asserted under stripe-mock — its fixture always reports amount_received=0)
  OK  psp_reference is a stripe-mock PaymentIntent (pi_RE3z1qccCW0HNt1)
  OK  orders[slot_at set] count >= 1 (got 1)
  OK  kiosk.settlements >= 1 (got 1)
  OK  order_items count >= 1 (got 3)
  OK  my_orders contains own order 1dba3640-c454-499a-b7ed-9b11193a856d

  All assertions passed.
```

Two negative controls ride inside the happy path and are the reason the `200`s
mean anything: a district-less delivery address is refused `400 bad_request`
before any slot is shown, and `create_order` against a window that has already
started is refused the same way. Both are wall-clock-dependent — this run was
recorded late in the Dublin day, so only the 18:00–20:00 window was still
bookable and slot `1` was available to be refused.

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the GetGrocery issuer and surface.
2. **Self-register** — generated an RSA-2048 keypair, proved possession of the private key (`GET /kiosk/auth/challenge` → signed the nonce as an origin-bound RS256 JWS → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`) → HTTP 201 → `agent_id`, `user_id`, `access_token`. No existing account. No human login. No OTP. No bot screen.
3. **Browse catalog** — `GET /kiosk/catalog` returned 16 in-stock products, sorted by name — the 15 groceries plus the age-restricted House Table Red Wine 750ml, which is the row that makes the age-gate beat below work (Milk 1 L and Chocolate Spread 400g are out of stock, so the catalog hides them — see `db/seeds.rb`). This worked example's driver builds the cart from the first three in-stock rows: Apple Juice (349c), Banana (149c), Butter 250g (349c), one of each.
4. **Query delivery slots** — `GET /kiosk/delivery_slots?date=2026-08-20&delivery_address=42%20Camden%20Street%2C%20Dublin%202` → returned the windows still bookable for that day, each carrying its resolved Dublin zone; the driver picked the first. In the run above that was `delivery_slot_id=6`, 18:00–20:00 in zone D02, because the earlier windows had already started. The driver asks for TODAY on purpose, so the assertion below it catches any drift between the day the slot was shown for and the day `create_order` books.
5. **Create order** — `POST /kiosk/create_order {items:[{sku:"apple-juice", qty:1}, {sku:"banana", qty:1}, {sku:"butter-250g", qty:1}], delivery_slot_id:6, delivery_date:"2026-08-20", delivery_address:"42 Camden Street, Dublin 2"}` → HTTP 200, `order_id`, `total_cents:847` (with `total_eur:"€8.47"` and `currency`), `slot_at`, and a `pay_hint`. Delivery is part of the order — slot and address are REQUIRED; the assistant composed the full cart (products referenced by `sku`), and passed back the DATE the slot was shown for so the booking cannot drift a day.
6. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:1047`, `scope:"grocery"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:847`, `line_items:[{order_id:<order_id>}, {sku:"apple-juice", qty:1, price_cents:349}, {sku:"banana", qty:1, price_cents:149}, {sku:"butter-250g", qty:1, price_cents:349}]` — mirroring the order per the `pay_hint`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws, cart_mandate_jws, payment_mandate_jws}` → the settlement itself: `{settlement_id, psp_reference, settled_amount_cents, currency:"eur"}`. Against real Stripe the settled amount is the order's own 847; the recording above ran on `stripe-mock`, whose fixture always reports `0`.
7. **(Optional) Move the delivery** — a PAID order's slot can be changed once via `POST /kiosk/reschedule_delivery {order_id:<order_id>, delivery_slot_id:<new_slot_id>}`. The operator's cashier check ran at capture: currency (EUR), each line against the catalog, and the total were verified before charging.

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
# ONE ENDPOINT PER VERB, and the HTTP method carries the semantics: a query is
# a GET whose arguments are the query string, an action a POST whose arguments
# are the JSON body. The reserved lines come first so they win by first-match;
# the per-verb pair is drawn LAST.
get  "/kiosk/schema",         to: "kiosk/server/wire#schema"
post "/kiosk/pay",            to: "kiosk/server/wire#pay"
get  "/kiosk/auth/challenge", to: "kiosk/server/auth#challenge"
post "/kiosk/auth/register",  to: "kiosk/server/auth#register"
post "/kiosk/auth/login",     to: "kiosk/server/auth#login"
post "/kiosk/auth/revoke",    to: "kiosk/server/auth#revoke"

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

Every registered verb, `pay`, and the public `schema` catalogue are wired end-to-end (AI-assistant self-discovery works — see `rake demo:schema`). (Mounting the engine draws all of this in one line; the block above is the hand-drawn equivalent, kept here because it shows what the mount actually installs.)

AI assistants call named queries BY NAME — `GET /kiosk/<query-name>` — never raw SQL. The operator registers the queries it wishes to expose; isolation is enforced at the app layer in the handler and in Actions, with RLS available as optional defense-in-depth.

**3. Declare the read verbs in a controller (and optionally apply RLS)**

The verbs an assistant may call are ordinary Rails controller actions. Kiosk
ships a MIXIN, not a base class — which superclass a handler has is your
decision — and each class-level macro is claimed by the next `def`, so a method
with no macros above it is a helper the wire cannot see. `input_schema` and
`output_schema` are REQUIRED on every verb: a declaration missing either raises
as the class body is read, so the app does not boot.

**The snippet below is ABRIDGED, not invented:** it is three of getgrocery's four
shipped queries (`kyc_status` is left out), with each verb's full prose
`description` and its per-property `description` lines elided and the argument
guards left to the shipped file. Every field name, type and `required` list is
the shipped one verbatim — read
`kiosk-demo-getgrocery/app/controllers/kiosk/storefront_controller.rb` for the
whole thing.

```ruby
# app/controllers/kiosk/storefront_controller.rb
class Kiosk::StorefrontController < ActionController::API
  include Kiosk::Query
  include KioskRefusals   # the app's own concern: renders a refusal result

  description "Browse in-stock products from the getgrocery catalog (out-of-stock items " \
              "are hidden). Each row carries the stable `sku` — reference a product by " \
              "that, never a numeric id — a `low` flag when stock is running out, and an " \
              "`age_restricted` flag on alcohol, which create_order accepts only after " \
              "an 18+ check (run request_kyc first)."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  # `low` and `age_restricted` are optional BY CONSTRUCTION: the handler appends
  # each only when it is true, so an absent flag means false — which is what
  # leaving them out of `required` says.
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { sku:            { type: "string" },
                                name:           { type: "string" },
                                price_cents:    { type: "integer" },
                                price_eur:      { type: "string" },
                                currency:       { type: "string" },
                                low:            { type: "boolean" },
                                age_restricted: { type: "boolean" } },
                  required: %w[sku name price_cents price_eur currency],
                }
  def catalog
    # The numeric primary key is deliberately NOT selected: a row id no verb
    # accepts is a dead field that invites the assistant to guess it is some
    # verb's param. `sku` is the only product handle on the wire.
    render json: Product.in_stock.order(:name)
                        .pluck(:sku, :name, :price_cents, :stock, :age_restricted)
                        .map { |sku, name, price_cents, stock, age_restricted|
                          row = { "sku"         => sku,
                                  "name"        => name,
                                  "price_cents" => price_cents,
                                  "price_eur"   => Product.format_eur(price_cents),
                                  "currency"    => "eur" }
                          row["low"]            = true if Product.low_stock?(stock)
                          row["age_restricted"] = true if Product.age_restricted?(age_restricted)
                          row
                        }
  end

  description "Get available delivery time slots for a date at a Dublin delivery address. " \
              "An out-of-zone address, or a date before today, is a 400 naming what is " \
              "needed. Each row carries a `delivery_slot_id` and its `date`; pass both to " \
              "create_order as `delivery_slot_id` and `delivery_date`."
  input_schema type: "object", additionalProperties: false,
               required: %w[date delivery_address],
               properties: {
                 date:             { type: "string", format: "date" },
                 delivery_address: { type: "string" },
               }
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { delivery_slot_id: { type: "integer" },
                                date:             { type: "string" },
                                slot_at:          { type: "string" },
                                label:            { type: "string" },
                                zone:             { type: "string" } },
                  required: %w[delivery_slot_id date slot_at label zone],
                }
  def delivery_slots
    # ADDRESS-UPFRONT: the delivery address is checked BEFORE the date, which is
    # what forces the assistant to obtain it from its human before it can even
    # see slots. This verb touches no table at all — the windows are a function
    # of the date and the operator's locale, the zone a function of the served
    # districts.
    zone, refusal = WireArguments.served_zone(params[:delivery_address])
    return render_refusal(refusal) if refusal

    date = Date.parse(params[:date])
    render json: DeliverySlots.bookable_ids(date).map { |slot_id|
      slot_time = DeliverySlots.slot_at(date, slot_id)
      hour      = slot_time.hour
      { "delivery_slot_id" => slot_id,
        "date"             => date.iso8601,
        "slot_at"          => slot_time.iso8601,
        "label"            => "#{hour.to_s.rjust(2, "0")}:00–" \
                              "#{(hour + DeliverySlots::WINDOW_HOURS).to_s.rjust(2, "0")}:00",
        "zone"             => zone }
    }
  end

  description "List this principal's orders with delivery slot, address, and a paid flag " \
              "(scoped to the authenticated user). Each row carries an `order_id`; pass it " \
              "to reschedule_delivery as `order_id`. Use the `paid` flag as a settlement " \
              "lookup: after a pay whose response you did not receive, re-read this and " \
              "retry pay only if the order is still unpaid."
  input_schema  type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: { order_id:    { type: "string" },
                                status:      { type: "string" },
                                total_cents: { type: "integer" },
                                slot_at:     { type: %w[string null] },
                                address:     { type: %w[string null] },
                                paid:        { type: "boolean" } },
                  required: %w[order_id status total_cents slot_at address paid],
                }
  def my_orders
    # `paid` is computed over the CALLER's settlements — the same containment
    # the operator's back office reads over all of them, so the two surfaces are
    # one behaviour with two authorities rather than two copies of one SQL string.
    render json: Order.owned_by_current_principal
                      .order(created_at: :desc)
                      .pluck(:id, :status, :total_cents, :slot_at, :address,
                             Order.paid_flag(Settlement.of_current_principal))
                      .map { |id, status, total_cents, slot_at, address, paid|
                        { "order_id"    => id,
                          "status"      => status,
                          "total_cents" => total_cents,
                          "slot_at"     => slot_at&.utc&.getlocal(0),
                          "address"     => address,
                          "paid"        => paid }
                      }
  end
end
```

A handler sees only assistant-supplied params and runs inside a session whose
`kiosk.current_user_id()` is the authenticated principal. `my_orders` scopes by
that server-derived UUID, never by an assistant-supplied one; the catalogue is
open to every authenticated assistant.

RLS is available as optional defense-in-depth via `enable_rls_on` — useful if
you want a Postgres-level backstop in addition to the app-layer checks. It is
not required for Kiosk's isolation model.

**4. Declare the write verbs next door (with ownership checks)**

A controller declares queries OR actions, never both. `reschedule_delivery` is
**payment-binding gated** — the Operation behind it verifies a settled mandate
references the order before mutating. `create_order` attaches ownership via
`kiosk.current_user_id()` and requires the delivery slot + address up front.

Abridged the same way as the read snippet above: two of getgrocery's four
shipped actions (`payment_setup` and `request_kyc` are left out), with the prose
`description` and the per-property `description` lines elided. Field names, types
and `required` lists are the shipped ones verbatim.

```ruby
# app/controllers/kiosk/orders_controller.rb
class Kiosk::OrdersController < ActionController::API
  include Kiosk::Action
  include KioskRefusals   # the app's own concern: turns an Operation result into a render

  description "Create (or replace) a grocery order for the authenticated principal. " \
              "Delivery is part of the order: a slot and an address are REQUIRED. " \
              "Nothing is charged until the cart is settled with `pay` — sign it in EUR " \
              "with line_items that mirror the order (the result carries a pay_hint)."
  input_schema type: "object", additionalProperties: false,
               required: %w[items delivery_slot_id delivery_address],
               properties: {
                 items: { type: "array", minItems: 1, items: {
                   type: "object", additionalProperties: false, required: %w[sku qty],
                   properties: { sku: { type: "string" }, qty: { type: "integer", minimum: 1 } },
                 } },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6 },
                 delivery_date:    { type: "string" },
                 delivery_address: { type: "string" },
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN },
               }
  output_schema type: "object", additionalProperties: false,
                properties: { order_id:    { type: "string" },
                              total_cents: { type: "integer" },
                              total_eur:   { type: "string" },
                              currency:    { type: "string" },
                              slot_at:     { type: "string" },
                              pay_hint:    { type: "string" } },
                required: %w[order_id total_cents total_eur currency slot_at pay_hint]
  def create_order
    # `user_id` is NOT a declared input: the principal comes from the identity
    # the wire resolved. Since input_schema closes the object and every 0.4 call
    # is validated against it, a forged one is refused with a typed 400 naming it.
    render_operation CreateOrderOperation.call(
      principal_id:     kiosk_identity.user_id,
      items:            kiosk_plain(params[:items]),
      delivery_slot_id: params[:delivery_slot_id],
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
      order_id:         params[:order_id],
    )
  end

  description "Move an ALREADY-PAID order's delivery to a different slot (and optionally " \
              "a new address). This REUSES the order's existing payment — do NOT pay " \
              "again. One reschedule per order; an unpaid order is re-placed via " \
              "create_order with order_id instead."
  input_schema type: "object", additionalProperties: false,
               required: %w[order_id delivery_slot_id],
               properties: {
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6 },
                 delivery_date:    { type: "string" },
                 delivery_address: { type: "string" },
               }
  # No price and no pay_hint, and that absence is the contract: a reschedule
  # reuses the order's existing payment, so there is no new mandate to sign.
  output_schema type: "object", additionalProperties: false,
                properties: { order_id:       { type: "string" },
                              rescheduled_at: { type: "string" } },
                required: %w[order_id rescheduled_at]
  def reschedule_delivery
    # The settled-mandate gate lives in the Operation, with the slot move, in one
    # transaction. A refusal is Rails' idiom, not a Kiosk class: render_operation
    # turns a refused result into
    #   render json: { error: { code: "forbidden", … } }, status: :forbidden
    #   — and the wire carries that `code` verbatim into an RFC 9457 problem document.
    render_operation RescheduleDeliveryOperation.call(
      order_id:         params[:order_id],
      delivery_slot_id: params[:delivery_slot_id],
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
    )
  end
end
```

**5. Name the controllers in the initializer**

```ruby
Kiosk.configure do |c|
  c.handlers = %w[Kiosk::StorefrontController Kiosk::OrdersController]
end
```

This line is load-bearing. The wire reaches a handler through the registry and
nothing else in the app references these classes, so in development — where
Rails does not eager-load `app/` — an origin that names none of them serves no
verbs at all. There is no second way in: `Kiosk::Server::Queries.register` was
removed in 0.3.

**6. Wire a payment-provider adapter**

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
