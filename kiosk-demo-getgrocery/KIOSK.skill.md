# Kiosk Skill — transact with any Kiosk provider

A personal agent (Hermes, Comet, OpenClaw, OpenSquilla, a capable Siri) follows these steps to discover, register, browse, act, and pay at any Kiosk provider — with no human account, no human login, and no human at the keyboard until the purchase is complete.

The human says: *"order groceries from GetGroceries."* The agent does everything else — including resolving substitutions for out-of-stock items before placing the order.

---

## Step 1 — Discover

```
GET /.well-known/kiosk.json
```

This returns the provider's `issuer` and `endpoint`. Read `issuer` — you copy it verbatim into the `iss` claim of every mandate you sign (Step 5), and `endpoint` is where you send the calls below. You browse the provider's domain data via provider-registered named `query` calls (Step 3) — you never send SQL.

---

## Step 2 — Self-register a synthetic principal (no human required)

Generate an RSA-2048 keypair. Keep the private key for the duration of this session; you will use it to sign mandates in Step 5.

```http
POST /kiosk/agents/register
Content-Type: application/json

{
  "name":       "hermes",
  "public_key": "<PEM-encoded RSA public key>",
  "role":       "customer"
}
```

Successful response — HTTP 201:

```json
{
  "agent_id":     "<uuid>",
  "user_id":      "<uuid>",
  "access_token": "<JWT>"
}
```

Store `agent_id`, `user_id`, and `access_token`. All subsequent requests carry `Authorization: Bearer <access_token>`.

No human is involved. There is no existing account at the provider. The provider creates a synthetic principal on the fly. This is the point: **the agent has no account at the provider and needs none.**

---

## Step 3 — Browse with `query` (named, parameterized — no SQL)

The agent **never sends SQL**. Instead, call a provider-registered named query by name and pass params. For GetGroceries, browse the catalog, available delivery slots, and your own orders:

**Browse the product catalog:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name": "catalog"
  }
}
```

The response is a `rows` array of in-stock products. Each row has `id`, `name`, and `price_cents`; rows with low remaining stock also include `"low": true`. Note the `id` of each product you want.

> **Substitutions are the assistant's decision.** The catalog returns in-stock items only — an item absent from the catalog is out of stock. The assistant reasons over the catalog: "Milk 1 L" not present → use 2× "Milk 0.5 L"; "Chocolate Spread" not present → ask the user (peanut butter?) or omit. The provider does not suggest substitutions.

**Check delivery slots:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name": "delivery_slots",
    "date": "<YYYY-MM-DD>"
  }
}
```

Returns available slots for the given date. Note the `id` of your preferred slot.

**View your orders:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name": "my_orders"
  }
}
```

App-layer isolation is in effect: `my_orders` scopes to the authenticated principal via `WHERE user_id = kiosk.current_user_id()` — no raw SQL, no RLS required. The `catalog` and `delivery_slots` queries are available to all authenticated agents.

---

## Step 4 — Act with `run`

Use the `run` command to invoke provider-registered Actions. GetGroceries exposes two actions: `create_order` and `schedule_delivery`.

**Create an order:**

The assistant submits the **whole cart at once** via `create_order`. There is no per-item incremental call.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":  "create_order",
    "items": [
      { "sku": "<sku>", "qty": 2 },
      { "sku": "<sku>", "qty": 1 }
    ]
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "order_id":    "<uuid>",
  "total_cents": 2499
}
```

Note `order_id` and `total_cents` — both are required for Step 5.

This action is **ownership-gated**: the server derives `user_id` from the authenticated session via `kiosk.current_user_id()` and attaches it to the order.

**Schedule delivery:**

This action is **payment-binding gated**: the server checks that a settled `kiosk.settlements` row exists whose cart mandate `line_items @> [{"order_id": <order_id>}]`. Call `pay` first (Step 5), then `schedule_delivery`.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":             "schedule_delivery",
    "order_id":         "<order_id from create_order>",
    "delivery_slot_id": "<slot id from delivery_slots>",
    "delivery_address": "42 Sakura Lane, Neo-Tokyo"
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "order_id":    "<uuid>",
  "scheduled_at": "<ISO8601 datetime>",
  "status":      "scheduled"
}
```

---

## Step 5 — Pay: sign AP2 intent + cart + payment mandates (RS256 JWS)

Payment requires three JWS tokens signed with the private key you generated in Step 2. The algorithm is RS256. The `iss` claim in all mandates **must equal the provider's issuer** (from `/.well-known/kiosk.json`).

### Intent mandate (spending cap)

```json
{
  "id":               "<fresh UUID>",
  "user_id":          "<user_id from Step 2>",
  "agent_id":         "<agent_id from Step 2>",
  "iss":              "<provider issuer>",
  "scope":            "grocery",
  "cap_amount_cents": <total_cents + buffer>,
  "currency":         "eur",
  "exp":              <now + 600>,
  "iat":              <now>
}
```

`cap_amount_cents` must be >= the order total. A small buffer (e.g. +100¢) is conventional.

### Cart mandate (actual charge, bound to the intent)

```json
{
  "id":                 "<fresh UUID>",
  "intent_mandate_id":  "<id from the intent mandate above>",
  "user_id":            "<user_id from Step 2>",
  "agent_id":           "<agent_id from Step 2>",
  "iss":                "<provider issuer>",
  "line_items":         [{ "order_id": "<order_id from create_order>", "total": <total_cents> }],
  "total_amount_cents": <total_cents from Step 4>,
  "currency":           "eur",
  "exp":                <now + 600>,
  "iat":                <now>
}
```

`intent_mandate_id` binds the cart mandate to the intent cap. Every mandate must be bound to your registered principal via `user_id` + `agent_id`.

### Payment mandate (the assistant's funding instrument, bound to the cart)

```json
{
  "id":              "<fresh UUID>",
  "cart_mandate_id": "<id from the cart mandate above>",
  "user_id":         "<user_id from Step 2>",
  "agent_id":        "<agent_id from Step 2>",
  "iss":             "<provider issuer>",
  "payment_method":  "<Stripe PaymentMethod id, e.g. pm_card_visa>",
  "amount_cents":    <total_cents from Step 4>,
  "currency":        "eur",
  "exp":             <now + 600>,
  "iat":             <now>
}
```

`cart_mandate_id` binds the payment mandate to the cart. `amount_cents` must match the cart total exactly — the server rejects mismatches. The `payment_method` is the assistant-presented Stripe PaymentMethod; the provider charges it via its PSP. The assistant presents the card; the provider stores nothing.

### Pay call

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "pay",
  "body": {
    "intent_mandate_jws":  "<RS256 JWS of intent payload>",
    "cart_mandate_jws":    "<RS256 JWS of cart payload>",
    "payment_mandate_jws": "<RS256 JWS of payment payload>"
  }
}
```

Successful response — HTTP 200:

```json
{
  "ok":    true,
  "kind":  "value",
  "value": {
    "settlement_id":        "<uuid>",
    "psp_reference":        "<provider PSP reference>",
    "settled_amount_cents": 2499,
    "currency":             "eur"
  }
}
```

After `pay` succeeds, call `schedule_delivery` (Step 4) to book the time slot.

---

## Handling `pow_required`

Any `/kiosk/exec` response may be HTTP 402 with `error.code == "pow_required"`.
When this happens, solve the challenge and retry — the full protocol is
documented in `kiosk-pow/SKILL.md`. Summary:

1. Install once: `pip install argon2-cffi`
2. Solve: `python3 kiosk-pow/solve.py '<challenge-json>'` → reads `{"nonce": "..."}`
3. Re-POST the **exact same** request body with a top-level `pow` field:
   ```json
   { "command": "query",
     "body":    { "name": "catalog" },
     "pow":     { "challenge": { ...verbatim... }, "nonce": "<from solver>" } }
   ```

Do not negotiate or downgrade the algorithm — solve what the provider demands
or tell the user to update. The provider may challenge again on any subsequent
request. The reference solver is `kiosk-pow/solve.py`.

---

## Self-discovery

Instead of relying solely on this static file, an agent can ask the provider
for a live, machine-readable catalog of every registered query and action:

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{ "command": "schema" }
```

Response — HTTP 200, inside `.value`:

```json
{
  "verbs":   ["query", "run", "pay", "schema", "help"],
  "queries": [
    { "name": "catalog",        "description": "Browse all in-stock products", "params": null },
    { "name": "delivery_slots", "description": "List available delivery slots for a date",
                                "params": { "date": "string — YYYY-MM-DD" } },
    { "name": "my_orders",      "description": "List this principal's orders", "params": null }
  ],
  "actions": [
    { "name": "create_order",      "description": "Submit a full cart as a new order",
                                   "params": { "items": "array of {sku: string, qty: integer}" } },
    { "name": "schedule_delivery", "description": "Book a delivery slot for a paid order",
                                   "params": { "order_id": "uuid", "delivery_slot_id": "integer",
                                               "delivery_address": "string" } }
  ]
}
```

For a human-readable rendering of the same catalog:

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{ "command": "help" }
```

Response `.value.text` is a plain-text listing of implemented verbs, queries,
and actions with their descriptions and param hints.

Use `schema` to discover what is available at runtime rather than hard-coding
query or action names from this file.

---

## Rules

1. **Generate the keypair once per session; keep the private key.** Mandate verification looks up the public key you registered. If you lose the key, re-register.
2. **Every mandate must be bound to your registered principal.** `user_id` and `agent_id` in both mandates must match the values returned by `/kiosk/agents/register`.
3. **`iss` must equal the provider's issuer.** Read it from `/.well-known/kiosk.json` and copy it verbatim into both mandates.
4. **Start by reading `/.well-known/kiosk.json`.** It gives you the `issuer` (for mandate signing) and the `endpoint` for `/kiosk/exec` before you send a single request.
5. **The cap must cover the total.** `cap_amount_cents` >= `total_amount_cents`. The cart mandate is rejected if it exceeds the cap.
6. **`intent_mandate_id` in the cart must reference the intent's `id`.** The server verifies this binding.
7. **Pay before scheduling.** `schedule_delivery` is payment-binding gated — the server verifies a settled mandate exists for the order before booking the slot.

---

## Worked example

`getgrocery_flow.rb` in this directory is a standalone Ruby script that executes this exact flow — register → query catalog → create_order {items} → query delivery_slots → pay (mandate: order_id) → schedule_delivery {order_id, slot, address} — against the GetGroceries demo app. It prints one JSON line on success and exits non-zero on any failure. Run it with:

```
SERVER_URL=http://127.0.0.1:3005 \
KIOSK_ISSUER=http://127.0.0.1:3005 \
bundle exec ruby getgrocery_flow.rb
```

This skill applies to any provider that exposes the Kiosk wire surface. The Actions (Step 4) and domain schema (Step 3) differ per provider; the registration, mandate structure, and pay verb are identical.
