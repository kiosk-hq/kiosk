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

getgrocery is a Rails 8 app that speaks Kiosk. Below is the output of
`bundle exec rake demo` (which is `demo:setup` then `demo:shop`, and `demo:shop`
is what runs `script/getgrocery_flow.rb`) — recorded **2026-08-26**, stdout and
stderr as a terminal shows them. The block starts at `demo:shop`'s FIRST line,
so what is cut is the whole of `demo:setup`'s output — and that is NOT only the
`db:drop`/`db:create`/`db:schema:load`/`db:seed` chatter and the seed listing it
ends with. Rake also echoes the two `psql` commands that create the `app_role`
role and grant it, Postgres answers the second of those with a
`NOTICE`/`LOCATION` pair, and the boot prints `[kiosk] WARNING: generated an
EPHEMERAL signing key` and a `[getgrocery] no STRIPE_SECRET_KEY/STRIPE_MOCK_URL
set` line. How many lines that comes to is a property of the machine and of the
environment — the `NOTICE` appears only where the grant is already in place, and
the Stripe line only where no key is set — which is why the declaration below
names the TASK rather than listing its output: run `rake demo:setup` to see
yours. From there down, `bin/check-demo-derivations` holds every line in the
block to a string literal one of the declared producers prints. That is a subset
test: it cannot show that no line is MISSING, so «the recording runs on to the
task's last line» is the `abridged:` field's claim and a human's signature,
not this script's.

**This recording is the secret-free path**, the one CI runs: with no
`STRIPE_SECRET_KEY` in the environment the task starts a local `stripe-mock`,
so `psp_reference` is a `stripe-mock` PaymentIntent and `settled_amount_cents`
is that fixture's constant `0` — which is why the run declines to assert the
settled amount and says so in an assertion of its own. Set a real `sk_test_…`
and the identical flow charges Stripe test mode instead; the task prefers a real
key whenever one is present.

<!-- derived: transcript | task: bundle exec rake demo | from: lib/tasks/demo.rake, script/getgrocery_flow.rb, script/equihash_register.rb | keys_from: app/controllers/kiosk/storefront_controller.rb, app/controllers/kiosk/orders_controller.rb | abridged: everything demo:setup prints, above the first line quoted -->
```
  (no STRIPE_SECRET_KEY — running against stripe-mock at http://127.0.0.1:12111, no real charge)
  (add to /etc/hosts: 127.0.0.1 getgrocery.demo.kiosk.tech -- using 127.0.0.1)

-- Starting getgrocery on http://127.0.0.1:3001 --
  Server up at http://127.0.0.1:3001

-- Running script/getgrocery_flow.rb --
  Registered: user_id=fe1a7146-dc21-4ea6-91ea-e1d560e386bc
  Catalog: 16 in-stock products (EUR)
  Ordering: sku=apple-juice, sku=banana, sku=butter-250g
  delivery_slots (district-less address): http=400 code=bad_request (rejected, as expected)
  delivery_slots: today is sold out (all windows started) — querying 2026-08-27
  Delivery slot: id=1 08:00–10:00 zone=D02 on 2026-08-27 (2026-08-27T08:00:00+01:00)
  create_order: order_id=1af6fb28-c05a-416b-adb6-a6965251808d total=€8.47 slot_at=2026-08-27T08:00:00+01:00
  payment_setup: ready
  pay: settlement_id=ebac3e74-9087-4560-adb3-14157fc4f48b psp_reference=pi_RGA0cgHgjoCS0YF
  my_orders: 1 order(s); own order payment_state=paid
{"http_register":201,"http_catalog":200,"http_slots":200,"http_slots_badzone":400,"slots_badzone_code":"bad_request","http_order":200,"http_payment_setup":200,"http_pay":200,"http_my_orders":200,"user_id":"fe1a7146-dc21-4ea6-91ea-e1d560e386bc","agent_id":"8be0b50f-573e-4d79-9ce2-9992476baef6","order_id":"1af6fb28-c05a-416b-adb6-a6965251808d","total_cents":847,"slot_at":"2026-08-27T08:00:00+01:00","chosen_slot_at":"2026-08-27T08:00:00+01:00","slot_date":"2026-08-27","past_slot_check":null,"payment_state":"paid","psp_reference":"pi_RGA0cgHgjoCS0YF","my_orders":[{"order_id":"1af6fb28-c05a-416b-adb6-a6965251808d","status":"paid","total_cents":847,"slot_at":"2026-08-27T07:00:00.000+00:00","address":"42 Camden Street, Dublin 2","payment_state":"paid"}],"pay":{"settlement_id":"ebac3e74-9087-4560-adb3-14157fc4f48b","psp_reference":"pi_RGA0cgHgjoCS0YF","settled_amount_cents":0,"currency":"eur"}}

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
  OK  order_id present (1af6fb28-c05a-416b-adb6-a6965251808d)
  OK  slot_at present (2026-08-27T08:00:00+01:00)
  OK  create_order slot_at == chosen delivery_slot slot_at (2026-08-27T08:00:00+01:00) — no date drift
  OK  K-480: no past slot to reject (booked tomorrow or before 08:00 Dublin) — filter is a no-op
  OK  my_orders own order payment_state == paid
  OK  pay.settlement_id present (ebac3e74-9087-4560-adb3-14157fc4f48b)
  OK  pay.psp_reference present (pi_RGA0cgHgjoCS0YF)
  OK  pay.settled_amount_cents present (0)
  OK  pay.currency present (eur)
  OK  the settlement is denominated in the operator's own currency (eur)
  OK  (settled amount not asserted under stripe-mock — its fixture always reports amount_received=0)
  OK  psp_reference is a stripe-mock PaymentIntent (pi_RGA0cgHgjoCS0YF)
  OK  this run's order has a delivery slot (id=1af6fb28-c05a-416b-adb6-a6965251808d)
  OK  exactly one kiosk.settlements row for this run's principal (fe1a7146-dc21-4ea6-91ea-e1d560e386bc)
  OK  this run's order has 3 order_items (id=1af6fb28-c05a-416b-adb6-a6965251808d)
  OK  my_orders contains own order 1af6fb28-c05a-416b-adb6-a6965251808d

  All assertions passed.
  Server stopped.
```

Two negative controls ride inside the happy path and are the reason the `200`s
mean anything: a district-less delivery address is refused `400 bad_request`
before any slot is shown, and `create_order` against a window that has already
started is refused the same way. The first fires on every run and did here
(`http_slots_badzone: 400`). **The second is wall-clock-dependent and did NOT
fire in this recording** — the run went out at 19:03 Dublin, by which time every
one of today's windows had started, so the driver did what a live assistant
would do and asked for tomorrow instead (`delivery_slots: today is sold out …
— querying 2026-08-27`). With the whole cart moved to a fresh day there was no
past slot left to offer, `past_slot_check` is `null`, and the past-slot
assertion reports itself a no-op rather than silently passing. Run the same task in the
Dublin afternoon and both controls fire.

**What the AI assistant did — no human involved at any step:**

1. **Discover** — `GET /.well-known/kiosk.json` returns the GetGrocery issuer and surface.
2. **Self-register, and pay the toll** — generated an RSA-2048 keypair and proved possession of the private key: `GET /kiosk/auth/challenge?public_key=<urlencoded pem>` (the query parameter is REQUIRED — without it the endpoint answers `400 missing public_key query parameter`) → signed the nonce as an origin-bound RS256 JWS → `POST /kiosk/auth/register {public_key:<pem>, signed:<jws>}`. **That first POST comes back `402`**: registration here is uniformly tolled (`c.registration_pow_count = 1`, `config/initializers/kiosk.rb`), and the 402 is an RFC 9457 problem document carrying a top-level `challenges` array the SERVER minted — so nothing can be solved in advance. The client solves each challenge and re-POSTs the SAME signed body with the proof in the `Kiosk-PoW` header → HTTP 201 → `agent_id`, `user_id`, `access_token`. The transcript shows only the `201`, because `http_register` is what the driver reports for the second POST. No existing account. No human login. No OTP. No bot screen.
3. **Browse catalog** — `GET /kiosk/catalog` returned 16 in-stock products, sorted by name — the 15 groceries plus the age-restricted House Table Red Wine 750ml, which is the row that makes the age-gate beat below work (Milk 1 L and Chocolate Spread 400g are out of stock, so the catalog hides them — see `db/seeds.rb`). This worked example's driver builds the cart from the first three in-stock rows: Apple Juice (349c), Banana (149c), Butter 250g (349c), one of each.
4. **Query delivery slots** — `GET /kiosk/delivery_slots?date=<today>&delivery_address=42%20Camden%20Street%2C%20Dublin%202` → returned the windows still bookable for that day, each carrying its resolved Dublin zone; the driver picked the first. The driver asks for TODAY on purpose, so the assertion below it catches any drift between the day the slot was shown for and the day `create_order` books — and when today comes back EMPTY, which is what «all windows started» means and what happened in the run above, it re-asks for tomorrow, exactly as a live assistant would. That is why the recording shows `delivery_slot_id=1`, the 08:00–10:00 window in zone D02 on `2026-08-27`.
5. **Create order** — `POST /kiosk/create_order {items:[{sku:"apple-juice", qty:1}, {sku:"banana", qty:1}, {sku:"butter-250g", qty:1}], delivery_slot_id:1, delivery_date:"2026-08-27", delivery_address:"42 Camden Street, Dublin 2"}` → HTTP 200, `order_id`, `total_cents:847` (with `total_eur:"€8.47"` and `currency`), `slot_at`, and a `pay_hint`. Delivery is part of the order — slot and address are REQUIRED; the assistant composed the full cart (products referenced by `sku`), and passed back the DATE the slot was shown for so the booking cannot drift a day.
6. **Pay** — signed an AP2 intent mandate (`cap_amount_cents:1047`, `scope:"grocery"`, `iss:<issuer>`) and a cart mandate (`total_amount_cents:847`, `line_items:[{order_id:<order_id>}, {sku:"apple-juice", qty:1, price_cents:349}, {sku:"banana", qty:1, price_cents:149}, {sku:"butter-250g", qty:1, price_cents:349}]` — mirroring the order per the `pay_hint`, bound to the intent via `intent_mandate_id`) as RS256 JWS with the registered keypair, then `POST /kiosk/pay {intent_mandate_jws, cart_mandate_jws, payment_mandate_jws}` → the settlement itself: `{settlement_id, psp_reference, settled_amount_cents, currency:"eur"}`. Against real Stripe the settled amount is the order's own 847; the recording above ran on `stripe-mock`, whose fixture always reports `0`.
7. **(Optional) Move the delivery** — a PAID order's slot can be changed once via `POST /kiosk/reschedule_delivery {order_id:<order_id>, delivery_slot_id:<new_slot_id>}`. The operator's cashier check ran at capture: currency (EUR), each line against the catalog, and the total were verified before charging.

The database confirmed: one row in `orders` with its delivery slot set (`slot_at`), one row in `kiosk.settlements`.

The business outcome: the user said "order groceries from GetGrocery." Their assistant completed the purchase — discovery, registration, catalog browse, order creation (delivery booked as part of the order), payment — without the user touching anything and without the user having an account at GetGrocery beforehand.

The operator outcome: GetGrocery received a real order and a payment settled through the real adapter — against `stripe-mock` in the run above, against Stripe test mode with a real `sk_test_…` key. The customer relationship stays with GetGrocery (the mandate carries the operator's issuer). There is no intermediate platform taking a discovery fee or owning the session.

**This is a demo against a fake operator, settled through the real Stripe adapter in test mode.** The mechanism works. Whether real operators will integrate and whether real users will value this enough to drive adoption are open questions — the demo does not answer them.

---

## What's needed — the operator adoption recipe

The delta between "today's Instacart" and "getgrocery" is an operator-side integration. The pieces:

**1. Add the Kiosk satellite gems**

<!-- derived: snippet | from: Gemfile | abridged: the kiosk gem lines and json_schemer only; the Rails/Postgres/dev-group lines around them are out -->
```ruby
# Gemfile
gem "kiosk-all",        path: "../kiosk-all"
gem "kiosk-core",       path: "../kiosk-core"
gem "kiosk-rls",        path: "../kiosk-rls"
gem "kiosk-server",       path: "../kiosk-server"
gem "kiosk-pow-equihash", path: "../kiosk-pow-equihash"
gem "kiosk-reputation",   path: "../kiosk-reputation"
gem "kiosk-redteam",      path: "../kiosk-redteam"
gem "kiosk-pay-stripe",   path: "../kiosk-pay-stripe"
gem "kiosk-user-idp-devise", path: "../kiosk-user-idp-devise"

gem "json_schemer"
```

Those are this demo's own `Gemfile` lines, verbatim, ragged alignment and all
(the `path:` overrides are the monorepo checkout; in production they are
versioned RubyGems). Not all nine are the minimum: `kiosk-core` +
`kiosk-server` is the engine, `kiosk-pay-stripe` is what makes this the demo
that takes real money, `kiosk-pow-equihash`/`kiosk-reputation` carry the
registration and catalogue tolls, `kiosk-redteam` is the adversarial battery,
`kiosk-user-idp-devise` the human-session channel, `kiosk-rls` the optional
Postgres backstop, and `json_schemer` is required only because this origin turns
`c.validate_requests` on.

**2. Run the generator**

<!-- derived: generator | from: kiosk-server/lib/generators/kiosk/install/install_generator.rb | why: a command an adopter types, held to the namespace that generator answers — derived from its path and again from its class nesting, so a rename fails here rather than rotting in three documents at once (K-1099) -->
```
rails g kiosk:install
```

This emits exactly two things: `config/initializers/kiosk.rb` (a `Kiosk.configure` block) and the `kiosk.*` schema migrations — the namespace itself, the identity tables (`agents`, `agent_tokens`, `agent_mappings`), `reservations`, `device_authorizations`, the AP2 mandate trail (`intent_mandates`, `cart_mandates`, `payment_mandates`, `settlements`) and `kyc_attributes`, one row per anonymized attribute an attestation granted. Run `bin/rails db:migrate` to apply them.

The generator does **not** touch your routes. `kiosk-server` ships the wire
controllers; you mount them yourself. Below are the Kiosk route statements this
demo's `config/routes.rb` actually draws, verbatim and in file order. Only that
file's own comments are trimmed, plus the lines that have nothing to do with the
Kiosk wire (`devise_for`, `root`, this demo's own `/kyc/callback` and
`/admin/orders`, a `/payment/return` landing page and a telemetry route drawn
only under `KIOSK_TELEMETRY=1`).

<!-- derived: snippet | from: config/routes.rb | transform: dedent | abridged: the Kiosk wire lines only, quoted without the routes.draw indent; this demo's own devise/root/admin/telemetry routes and every comment are out -->
```ruby
# config/routes.rb — the wire surface, hand-drawn.
get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
post "/kiosk/pay",                               to: "kiosk/server/wire#pay"
get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"

get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"
post "/kiosk/agents/kyc",                        to: "kiosk/server/kyc_attestation#create"

get "/agents.txt",                        to: "kiosk/server/discovery#agents_txt"
get "/agents.json",                       to: "kiosk/server/discovery#agents_json"
get "/.well-known/agent-configuration",   to: "kiosk/server/discovery#agent_configuration"
get "/.well-known/kiosk.json",            to: "kiosk/server/discovery#kiosk_json"
get "/.well-known/api-catalog",           to: "kiosk/server/discovery#api_catalog"
get "/kiosk/openapi.json",                to: "kiosk/server/open_api#show"

get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
     constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
```

**Every controller in that table is kiosk-server's** — including
`/.well-known/kiosk.json`, which is `Kiosk::Server::DiscoveryController#kiosk_json`
rendering the `WellKnown.build_json` document; there is nothing here for an
operator to implement and no Rack lambda to hand-write. ONE ENDPOINT PER VERB,
and the HTTP method carries the semantics: a query is a GET whose arguments are
the query string, an action a POST whose arguments are the JSON body. The
reserved lines come first so they win by first-match; the per-verb pair is drawn
LAST. Every registered verb, `pay`, and the public `schema` catalogue are wired
end-to-end (AI-assistant self-discovery works — see `rake demo:schema`).
Mounting the engine draws all of this in one line; the block above is the
hand-drawn equivalent, kept here because it shows what the mount actually
installs.

AI assistants call named queries BY NAME — `GET /kiosk/<query-name>` — never raw SQL. The operator registers the queries it wishes to expose; isolation is enforced at the app layer in the handler and in Actions, with RLS available as optional defense-in-depth.

**3. Declare the read verbs in a controller (and optionally apply RLS)**

The verbs an assistant may call are ordinary Rails controller actions. Kiosk
ships a MIXIN, not a base class — which superclass a handler has is your
decision — and each class-level macro is claimed by the next `def`, so a method
with no macros above it is a helper the wire cannot see. `input_schema` and
`output_schema` are REQUIRED on every verb: a declaration missing either raises
as the class body is read, so the app does not boot.

**The snippet below is ABRIDGED, and every abridgement is marked where it
happens.** It was DERIVED from
`kiosk-demo-getgrocery/app/controllers/kiosk/storefront_controller.rb` by
deleting text, never by rewriting it. Every line below is a line of that file
with its `description` cut out and nothing else altered — no rewording, no
reordering, nothing invented — and the two kinds of elision marker say so on
their own line. Three things were deleted. (1) One of getgrocery's four shipped
queries, `kyc_status`. (2) Each remaining verb's prose `description`, collapsed
to a `description "…"   # elided` line, and every `description:` key inside a
schema. (3) Part of `delivery_slots`'s guards, at an explicit `GUARDS ELIDED`
marker. Everything else — field names, types, `required` lists, `enum`s,
`example_params`, `example_row` and the guards that remain — is the shipped
declaration.

<!-- derived: snippet | from: app/controllers/kiosk/storefront_controller.rb | transform: strip_descriptions | abridged: the kyc_status verb, each remaining verb's prose description, every schema description: key, and delivery_slots' guards at a marked line -->
```ruby
# app/controllers/kiosk/storefront_controller.rb
class Kiosk::StorefrontController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # ── catalog — the public shelf. No per-principal scoping: every authenticated
  # agent browses the same in-stock catalogue.
  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `low` and `age_restricted` are OPTIONAL by construction: the handler appends
  # each only when true, because publishing `false` on every ordinary grocery
  # would be noise in the largest catalogue in the fleet. An ABSENT flag means
  # false, which is what the `required` list below says.
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    sku:            { type: "string" },
                    name:           { type: "string" },
                    price_cents:    { type: "integer" },
                    price_eur:      { type: "string" },
                    currency:       { type: "string" },
                    low:            { type: "boolean" },
                    age_restricted: { type: "boolean" },
                  },
                  required: %w[sku name price_cents price_eur currency],
                }
  example_params({})
  example_row({
    sku: "sourdough-bread", name: "Sourdough Bread", price_cents: 449,
    price_eur: "€4.49", currency: "eur",
  })
  def catalog
    # `pluck` rather than loading models: naming the columns keeps the wire's
    # field names AND THEIR ORDER a decision this handler makes rather than a
    # side effect of the schema. `sku` is the only product handle on the wire —
    # the numeric primary key is deliberately not selected, because a row id no
    # verb accepts invites the assistant to guess it is some verb's param.
    render json: Product.in_stock
                        .order(:name)
                        .pluck(:sku, :name, :price_cents, :stock, :age_restricted)
                        .map { |sku, name, price_cents, stock, age_restricted|
                          row = { "sku"         => sku,
                                  "name"        => name,
                                  "price_cents" => price_cents,
                                  "price_eur"   => Product.format_eur(price_cents),
                                  "currency"    => "eur" }
                          row["low"] = true if Product.low_stock?(stock)
                          # Advertise the 18+ gate so an assistant completes KYC
                          # BEFORE ordering. Read through the same fail-closed
                          # predicate create_order enforces with, so the shelf
                          # and the gate cannot disagree about one row.
                          row["age_restricted"] = true if Product.age_restricted?(age_restricted)
                          row
                        }
  end

  # ── delivery_slots — the still-bookable windows for a date at an IN-ZONE
  # Dublin address. Touches no table: the windows are a function of the date and
  # the operator's locale ({DeliverySlots}), the address of the served districts
  # ({DublinZones}).
  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 date:             { type: "string", format: "date" },
                 delivery_address: { type: "string" },
               },
               required: ["date", "delivery_address"]
  # EMPTY is an honest answer here and ONLY here: every one of today's windows
  # may already have begun, in which case the earliest bookable slot is on a
  # later date. A date BEFORE today answers 400 instead.
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    delivery_slot_id: { type: "integer" },
                    date:             { type: "string" },
                    slot_at:          { type: "string" },
                    label:            { type: "string" },
                    zone:             { type: "string" },
                  },
                  required: %w[delivery_slot_id date slot_at label zone],
                }
  # THE DATE IS RESOLVED, NOT WRITTEN DOWN: a calendar literal is an
  # example that ages into a 400, since a date before today is REFUSED. These are
  # RESOLVABLE slots (see {Kiosk::Server::SchemaSlots}), so both name
  # {DeliverySlots.example_date} — tomorrow in the operator's own clock.
  example_params({ date:             -> { DeliverySlots.example_date.iso8601 },
                   delivery_address: "42 Camden Street, Dublin 2" })
  example_row({ delivery_slot_id: 1,
                date:    -> { DeliverySlots.example_date.iso8601 },
                slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 1).iso8601 },
                label: "08:00–10:00", zone: "D02" })
  def delivery_slots
    # `params.key?` and not `blank?`: an ABSENT date is "missing param: date"
    # while one that is present and empty falls through to the parser and is
    # "invalid date: ". That is a question about the request ENVELOPE, which the
    # controller is the only place that can ask.
    return render_refusal(missing_param("date")) unless params.key?(:date)

    # ADDRESS-UPFRONT: checked BEFORE the date, which is what forces the
    # assistant to obtain the address from its human before it can see slots.
    return render_refusal(WireArguments.missing_address) if params[:delivery_address].blank?

    zone, zone_refusal = WireArguments.served_zone(params[:delivery_address])
    return render_refusal(zone_refusal) if zone_refusal

    # ── GUARDS ELIDED HERE (this comment is the document's, not the file's) ──
    # What follows in the shipped file is the date parse — an unparseable value
    # is a named `bad_request`, not an exception — and then
    # `WireArguments.past_date`, which refuses a date BEFORE today by name,
    # because `200 []` for it would be indistinguishable from the one honest
    # empty case below. The method then ends with the lines below, which ARE the
    # shipped ones.

    # PAST-SLOT FILTER: for TODAY, drop any slot whose start has already passed
    # in the operator's locale; future dates keep all slots. An assistant should
    # not see an un-bookable 08:00–10:00 window at 11:00. `date` on each row is
    # what create_order books.
    render json: DeliverySlots.bookable_ids(date).map { |slot_id|
      slot_time = DeliverySlots.slot_at(date, slot_id)
      hour      = slot_time.hour
      { "delivery_slot_id" => slot_id,
        "date"    => date.iso8601,
        "slot_at" => slot_time.iso8601,
        "label"   => "#{hour.to_s.rjust(2, "0")}:00–#{(hour + DeliverySlots::WINDOW_HOURS).to_s.rjust(2, "0")}:00",
        "zone"    => zone }
    }
  end

  # ── my_orders — per-principal: the caller's OWN orders only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable.
  #
  # THE RECONCILIATION SURFACE: this is the "per-user query"
  # protocol.md §11.6 sends an assistant to after a `pay` whose response it never
  # read, so what it publishes about money is normative. `payment_state` is a
  # TRI-state and not a boolean, because a boolean conflates "nothing was ever
  # charged" with "a charge is outstanding" — and the second is where a fresh
  # mandate chain charges a human twice.
  kind :query
  description "…"   # elided — see the shipped file
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `slot_at` and `address` are the two nullable columns on `orders` and travel
  # as null rather than being dropped, so the row shape does not change with the
  # order's completeness.
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    order_id:      { type: "string" },
                    status:        { type: "string" },
                    total_cents:   { type: "integer" },
                    slot_at:       { type: %w[string null] },
                    address:       { type: %w[string null] },
                    payment_state: { type: "string", enum: %w[unpaid pending paid] },
                  },
                  required: %w[order_id status total_cents slot_at address payment_state],
                }
  def my_orders
    # The paid witness is {Order.paid_flag} over the CALLER's settlements — the
    # same containment the operator's back office reads over ALL of them, so the
    # two surfaces are one behaviour with two authorities rather than two copies
    # of one SQL string (see {Order.settling}).
    render json: Order.owned_by_current_principal
                      .order(created_at: :desc)
                      .pluck(:id, :status, :total_cents, :slot_at, :address,
                             Order.paid_flag(Settlement.of_current_principal))
                      .map { |id, status, total_cents, slot_at, address, paid|
                        { "order_id"      => id,
                          "status"        => status,
                          "total_cents"   => total_cents,
                          # `pluck` casts a timestamptz to a TimeWithZone, whose
                          # JSON rendering of a UTC instant is "…Z" where this
                          # field publishes "…+00:00". Same instant, and the
                          # `getlocal(0)` is what keeps the spelling.
                          "slot_at"       => slot_at&.utc&.getlocal(0),
                          "address"       => address,
                          "payment_state" => Order.payment_state(status, paid) }
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

The kind of verb is a property of each DECLARATION (`kind :action` below), not
of the class, so one controller could carry all eight; two is this demo's shape,
not a rule.
`reschedule_delivery` is
**payment-binding gated** — the Operation behind it verifies a settled mandate
references the order before mutating. `create_order` requires the delivery slot
and address up front, and attaches ownership from the identity the WIRE
resolved: the handler passes `principal_id: kiosk_identity.user_id` and the
INSERT writes `user_id: principal_id`. That is the write side, and it is worth
distinguishing from the read side, because they use different mechanisms for the
same identity: `kiosk.current_user_id()` is how owner-scoped READS are filtered
(`Order.owned_by_current_principal`'s WHERE predicate), and an INSERT has no
WHERE predicate to hide it in, so the column is written explicitly. Neither one
can be supplied by the assistant.

Derived from
`kiosk-demo-getgrocery/app/controllers/kiosk/orders_controller.rb` the same way
as the read snippet: every line is that file's with its `description` cut out
and nothing else altered, and the two `description "…"   # elided` markers say
so. Two of getgrocery's four shipped
actions, `payment_setup` and `request_kyc`, are left out; the other two are here
whole, bodies included.

<!-- derived: snippet | from: app/controllers/kiosk/orders_controller.rb | transform: strip_descriptions | abridged: the payment_setup and request_kyc verbs, and both remaining verbs' prose descriptions -->
```ruby
# app/controllers/kiosk/orders_controller.rb
class Kiosk::OrdersController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # create_order — the flagship verb; see {CreateOrderOperation} for the six
  # gates. The principal comes from the identity the wire resolved, so `user_id`
  # is NOT a declared input — and because `input_schema` closes the object
  # (`additionalProperties: false`) and is validated on every call, a forged one
  # is refused with a typed 400 naming it rather than silently ignored.
  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 items: {
                   type: "array", minItems: 1,
                   items: {
                     type: "object", additionalProperties: false,
                     properties: {
                       sku: { type: "string" },
                       # THE CEILING IS DECLARED, because a refusal the
                       # published schema does not predict is its own defect.
                       # `order_items.qty` is a PostgreSQL `integer`, so this is
                       # the column's own width and not an invented basket size.
                       # The cart's TOTAL is bounded too and is NOT expressible
                       # here — it is a sum of the operator's catalogue prices —
                       # so the verb description above states that half in words.
                       qty: { type: "integer", minimum: 1, maximum: WireArguments::MAX_INT4 },
                     },
                     required: ["sku", "qty"],
                   },
                 },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6 },
                 delivery_date:    { type: "string" },
                 delivery_address: { type: "string" },
                 # `pattern`/`format` so the DECLARED contract carries the shape the
                 # handler enforces (UuidCheck), which a bare {type:"string"} does not.
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN },
               },
               required: ["items", "delivery_slot_id", "delivery_address"]
  output_schema type: "object",
                additionalProperties: false,
                properties: {
                  order_id:    { type: "string" },
                  total_cents: { type: "integer" },
                  total_eur:   { type: "string" },
                  currency:    { type: "string" },
                  slot_at:     { type: "string" },
                  pay_hint:    { type: "string" },
                },
                required: %w[order_id total_cents total_eur currency slot_at pay_hint]
  # THE DELIVERY DAY IS RESOLVED, NOT WRITTEN DOWN: a literal here would
  # publish a `delivery_date` the operation refuses as past. `slot_at` derives
  # from the SAME day and the slot id beside it, so they cannot drift apart.
  example_params({
    items: [{ sku: "sourdough-bread", qty: 2 }, { sku: "greek-yogurt", qty: 1 }],
    delivery_slot_id: 3,
    delivery_date:    -> { DeliverySlots.example_date.iso8601 },
    delivery_address: "42 Camden Street, Dublin 2",
  })
  example_row({
    order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", total_cents: 1287,
    total_eur: "€12.87", currency: "eur",
    slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 },
    pay_hint: "pay in EUR with a cart mandate whose line_items mirror this order …",
  })
  def create_order
    render_operation CreateOrderOperation.call(
      principal_id:     kiosk_identity.user_id,
      items:            kiosk_plain(params[:items]),
      delivery_slot_id: params[:delivery_slot_id],
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
      order_id:         params[:order_id],
    )
  end

  # reschedule_delivery — move an ALREADY-PAID order's delivery. See
  # {RescheduleDeliveryOperation}. No call signature in the prose: ADR-0023
  # §Decision 4 puts the arguments, and which are optional, in `input_schema`.
  kind :action
  description "…"   # elided — see the shipped file
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 # Same uuid shape as create_order's order_id — see UuidCheck.
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6 },
                 delivery_date:    { type: "string" },
                 delivery_address: { type: "string" },
               },
               required: ["order_id", "delivery_slot_id"]
  # No price and no pay_hint, and that absence is the contract: a reschedule
  # REUSES the order's existing payment, so there is no new mandate to sign.
  output_schema type: "object",
                additionalProperties: false,
                properties: {
                  order_id:       { type: "string" },
                  rescheduled_at: { type: "string" },
                },
                required: %w[order_id rescheduled_at]
  # Resolved for {DeliverySlots.example_date}'s reason.
  example_params({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", delivery_slot_id: 3,
                   delivery_date: -> { DeliverySlots.example_date.iso8601 } })
  example_row({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e",
                rescheduled_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 } })
  def reschedule_delivery
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

<!-- derived: snippet | from: config/initializers/kiosk.rb | abridged: the handler-naming lines only, out of the Kiosk.configure block -->
```ruby
Kiosk.configure do |c|
  c.handlers = %w[Kiosk::StorefrontController Kiosk::OrdersController]
end
```

This line is load-bearing. The wire reaches a handler through the registry and
nothing else in the app references these classes, so in development — where
Rails does not eager-load `app/` — an origin that names none of them serves no
verbs at all. There is no second way in: `Kiosk::Server::Queries.register`, the block API
the 0.3 series shipped, was removed in 0.4 and now raises NoMethodError.

**6. Wire a payment-provider adapter**

These are the lines the two named files actually carry, verbatim:

<!-- derived: snippet | from: config/environments/production.rb | abridged: the two stripe lines only, out of the whole environment file -->
```ruby
# config/environments/production.rb — ENV is read per environment, once
  config.x.kiosk.stripe_mock_url   = ENV["STRIPE_MOCK_URL"].presence
  config.x.kiosk.stripe_secret_key = ENV["STRIPE_SECRET_KEY"].presence ||
                                     (config.x.kiosk.stripe_mock_url ? "sk_test_mock" : nil)
```

<!-- derived: snippet | from: config/initializers/kiosk.rb | abridged: only the issuer line, the Stripe key lookup with its mock-base branch and its blank guard, and the payment-provider call down to where the quote stops, out of the Kiosk.configure block -->
```ruby
# config/initializers/kiosk.rb — the initializer reads the resolved values
  c.issuer = Rails.configuration.x.kiosk.issuer

  key = Rails.configuration.x.kiosk.stripe_secret_key
  if (mock = Rails.configuration.x.kiosk.stripe_mock_url).present?
    require "stripe"
    Stripe.api_base = mock                          # e.g. http://127.0.0.1:12111
  end
  raise "getgrocery requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" if key.blank?

  c.payment_provider = ValidatingPaymentProvider.new(
    Kiosk::PaymentProviders::Stripe.new(
      api_key:           key,
      customer_resolver: ->(uid) { StripeCustomer.find_by(user_id: uid)&.customer_id },
      customer_saver:    ->(uid, cid) { StripeCustomer.create!(user_id: uid, customer_id: cid) },
      test_autocard:     Rails.configuration.x.kiosk.test_autocard,
      return_url:        "#{Kiosk.configuration.issuer}/payment/return",
    ),
```

(The `ValidatingPaymentProvider.new(` call continues in the shipped file with
the currency and catalogue arguments the cashier check reads.) Three things
worth reading out of it. **The credentials come from the environment file, not
from `ENV` here** — production hands back exactly what was supplied and invents
nothing, and an origin that advertises `pay` and then cannot charge refuses to
boot rather than failing at the first charge. **A configured `STRIPE_MOCK_URL`
is not a fallback but an explicit act** — it is what lets CI and the adversarial
suites run the full pay→settlement flow with no key and no real charge, and it
is the path the recording at the top of this page took. **And the Stripe adapter
is WRAPPED**, not used bare: `ValidatingPaymentProvider` is this app's cashier
check, verifying the agent-signed cart against getgrocery's own catalogue —
currency, per-line prices, total — before anything is captured.

With a real `sk_test_…` this demo uses the **real Stripe adapter in test mode**: the buyer's card is saved once via a hosted SetupIntent and charged `off_session` per purchase — the assistant never holds card data.

**What this does not require:** a new user-facing login flow, a new mobile app, an OAuth integration, a webhook endpoint, or a migration on any table you already own. The satellite gems add a parallel surface in their own `kiosk.*` schema; your tables keep their columns and your human-facing app keeps working unchanged.

What it DOES touch, and this demo is honest about it because an adopter will hit it on day one: a handful of additions to `app/models/order.rb`, an operator model. `owned_by_current_principal` is the `kiosk.current_user_id()` scope every owner-scoped read goes through, written once so the app-layer check and the optional RLS policy are the same expression; `paid_flag`, `settling` and `payment_state` are what turn the settlement evidence into the tri-state `my_orders` publishes. None of them changes the schema, and all of them are the sort of thing you would write anyway to expose a model over any API.

**What this enables:** any personal AI assistant that discovers the `issuer` and `endpoint` via `/.well-known/kiosk.json` and reads the served surface via `GET /kiosk/schema` (see `rake demo:schema`) can complete a grocery order without the user having an account at the operator and without the user being present. The operator drops its anti-bot wall for sanctioned AI-assistant traffic; the anti-bot wall stays in place for everything else.

See `script/getgrocery_flow.rb` in this directory for the full worked example.

---

*Validation research: primary evidence from live connector probes (Uber Eats, Booking.com) plus independent verification of OpenAI Instant Checkout walkback, Amazon v. Perplexity injunction, and Google Universal Cart, all as of 2026-06-22 — except the litigation, which moved and is restated rather than left to the date stamp: the Amazon v. Perplexity preliminary injunction was VACATED by the Ninth Circuit on 2026-08-04 (No. 26-1444), holding that a user who tasks an agent is the one who "accessed" the site, while expressly leaving contract claims open. A date stamp says when a finding was true, not that it stopped being true, and that is not enough for a pending case.*
