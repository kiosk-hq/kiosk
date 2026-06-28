# Kiosk Skill — transact with any Kiosk provider

A personal agent (Hermes, Comet, OpenClaw, OpenSquilla, a capable Siri) follows these steps to discover, register, browse, act, and pay at any Kiosk provider — with no human account, no human login, and no human at the keyboard until the purchase is complete.

The human says: *"order groceries from getgrocery."* The agent does everything else — including negotiating substitutions for out-of-stock items.

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

The agent **never sends SQL**. Instead, call a provider-registered named query by name and pass params. For getgrocery, browse the store catalog and product listings:

**List stores:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name": "stores"
  }
}
```

The response is a `rows` array. Pick a store — note its `id`.

**Browse products in a store:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name":     "products_by_store",
    "store_id": "<store id from stores>"
  }
}
```

Pick the products you want — note each product's `id`, `price_cents`, and `stock`. A `stock` of 0 means the item is out of stock; check `substitution_policy` for whether a suggested alternative is available.

**Check substitution options (for OOS items):**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name":       "substitution_options",
    "product_id": "<id of OOS product>"
  }
}
```

Returns the provider-suggested substitute product(s). Note the substitute's `suggested_product_id`.

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

Note the `id` of your preferred slot.

App-layer isolation is in effect: the `my_orders` query scopes to the authenticated principal via `WHERE user_id = kiosk.current_user_id()` — no raw SQL, no RLS required. Catalogue queries (`stores`, `products_by_store`, `substitution_options`, `delivery_slots`) are available to all authenticated agents.

---

## Step 4 — Act with `run`

Use the `run` command to invoke provider-registered Actions. getgrocery exposes three actions: `add_to_cart`, `apply_substitution`, and `confirm_delivery`.

**Add items to cart:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":       "add_to_cart",
    "store_id":   "<store id>",
    "product_id": "<product id from Step 3>",
    "qty":        1
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "cart_id":      "<uuid>",
  "cart_item_id": "<uuid>",
  "store_id":     "<id>",
  "product_id":   "<id>",
  "qty":          1
}
```

Note `cart_id` — all subsequent cart operations reference it. Calling `add_to_cart` again for the same principal returns the same `cart_id`.

**Accept or reject a substitution (OOS items):**

When a product is out of stock, the agent calls `apply_substitution` to accept or reject the suggested alternative — **no human interaction required:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":                    "apply_substitution",
    "cart_id":                 "<cart_id from add_to_cart>",
    "cart_item_id":            "<cart_item_id of OOS item>",
    "substitution_product_id": "<suggested_product_id from substitution_options>",
    "accept":                  true
  }
}
```

Set `accept: false` to reject the substitution and remove the OOS item from the cart.

This action is **cart-ownership gated**: the server enforces `WHERE id = cart_id AND user_id = kiosk.current_user_id()` — only the cart's owner can apply substitutions.

**Confirm delivery:**

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":             "confirm_delivery",
    "cart_id":          "<cart_id>",
    "delivery_slot_id": "<slot id from delivery_slots>",
    "delivery_address": "1 Test St, Istanbul"
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "delivery_id":  "<uuid>",
  "scheduled_at": "<ISO8601 datetime>",
  "total_cents":  2499,
  "status":       "confirmed"
}
```

Note `delivery_id` and `total_cents` — both are required for Step 5.

This action is also **cart-ownership gated**: the server enforces `WHERE id = cart_id AND user_id = kiosk.current_user_id()`.

---

## Step 5 — Pay: sign AP2 intent + cart mandates (RS256 JWS)

Payment requires two JWS tokens signed with the private key you generated in Step 2. The algorithm is RS256. The `iss` claim in both mandates **must equal the provider's issuer** (from `/.well-known/kiosk.json`).

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

`cap_amount_cents` must be >= the delivery total. A small buffer (e.g. +100¢) is conventional.

### Cart mandate (actual charge, bound to the intent)

```json
{
  "id":                 "<fresh UUID>",
  "intent_mandate_id":  "<id from the intent mandate above>",
  "user_id":            "<user_id from Step 2>",
  "agent_id":           "<agent_id from Step 2>",
  "iss":                "<provider issuer>",
  "line_items":         [{ "delivery_id": "<delivery_id from Step 4>", "total": <total_cents> }],
  "total_amount_cents": <total_cents from Step 4>,
  "currency":           "eur",
  "exp":                <now + 600>,
  "iat":                <now>
}
```

`intent_mandate_id` binds the cart mandate to the intent cap. Every mandate must be bound to your registered principal via `user_id` + `agent_id`.

### Pay call

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "pay",
  "body": {
    "intent_mandate_jws": "<RS256 JWS of intent payload>",
    "cart_mandate_jws":   "<RS256 JWS of cart payload>"
  }
}
```

Successful response — HTTP 200:

```json
{
  "ok":    true,
  "kind":  "value",
  "value": {
    "payment_mandate_id":   "<uuid>",
    "psp_reference":        "<provider PSP reference>",
    "settled_amount_cents": 2499,
    "currency":             "eur"
  }
}
```

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
     "body":    { "name": "stores" },
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
    { "name": "stores",               "description": "Browse the public store catalog", "params": null },
    { "name": "products_by_store",    "description": "Browse products for a given store",
                                      "params": { "store_id": "integer — store id" } },
    { "name": "substitution_options", "description": "Get suggested substitutes for an out-of-stock product",
                                      "params": { "product_id": "integer — product id" } },
    { "name": "delivery_slots",       "description": "List available delivery slots for a date",
                                      "params": { "date": "string — YYYY-MM-DD" } },
    { "name": "my_orders",            "description": "List this principal's confirmed deliveries", "params": null }
  ],
  "actions": [
    { "name": "add_to_cart",        "description": "Add a product to the authenticated principal's cart",
                                    "params": { "store_id": "integer", "product_id": "integer", "qty": "integer" } },
    { "name": "apply_substitution", "description": "Accept or reject a substitution for an out-of-stock cart item",
                                    "params": { "cart_id": "uuid", "cart_item_id": "uuid",
                                                "substitution_product_id": "integer", "accept": "boolean" } },
    { "name": "confirm_delivery",   "description": "Confirm the cart as a delivery order",
                                    "params": { "cart_id": "uuid", "delivery_slot_id": "integer",
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

---

## Worked example

`getgrocery_flow.rb` in this directory is a standalone Ruby script that executes this exact flow — register → browse stores → browse products → add_to_cart → query substitution_options → apply_substitution → query delivery_slots → confirm_delivery → sign mandates → pay — against the getgrocery demo app. It prints one JSON line on success and exits non-zero on any failure. Run it with:

```
SERVER_URL=http://127.0.0.1:3005 \
KIOSK_ISSUER=http://127.0.0.1:3005 \
bundle exec ruby getgrocery_flow.rb
```

This skill applies to any provider that exposes the Kiosk wire surface. The Actions (Step 4) and domain schema (Step 3) differ per provider; the registration, mandate structure, and pay verb are identical.
