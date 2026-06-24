# Kiosk Skill — transact with any Kiosk provider

A personal agent (Hermes, Comet, OpenClaw, OpenSquilla, a capable Siri) follows these steps to discover, register, browse, act, and pay at any Kiosk provider — with no human account, no human login, and no human at the keyboard until the purchase is complete.

The human says: *"order a Margherita from foodelivery."* The agent does everything else.

---

## Step 1 — Discover

```
GET /.well-known/kiosk.json
```

This returns the provider's `issuer` and `endpoint`. Read `issuer` — you copy it verbatim into the `iss` claim of every mandate you sign (Step 5), and `endpoint` is where you send the calls below. You browse the provider's domain data directly with `sql` (Step 3).

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

## Step 3 — Browse with `sql`

Use the `sql` command to read the provider's domain data.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "sql",
  "body": {
    "sql": "SELECT mi.id, mi.name, mi.sku, mi.price_cents
            FROM menu_items mi
            JOIN restaurants r ON r.id = mi.restaurant_id
            WHERE r.name = 'Mamma Pizza'
            ORDER BY mi.id"
  }
}
```

The response is a `rows` array. Pick the item you want — note its `id` and `price_cents`.

Row-level security is in effect: `orders` are visible only to the registered principal. Catalogue tables (`restaurants`, `menu_items`) are public-readable.

---

## Step 4 — Act with `run` (e.g. `place_order`)

Use the `run` command to invoke a provider-registered Action. Action names are provider-specific — `foodelivery` exposes `place_order`.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":             "place_order",
    "menu_item_id":     "<id from Step 3>",
    "quantity":         1,
    "delivery_address": "1 Test St, Istanbul"
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "order_id":      "<uuid>",
  "restaurant_id": 1,
  "total_cents":   1599,
  "status":        "placed"
}
```

Note `order_id` and `total_cents` — both are required for Step 5.

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
  "scope":            "food",
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
  "line_items":         [{ "sku": "margherita", "qty": 1 }],
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
    "payment_mandate_id":  "<uuid>",
    "psp_reference":       "<provider PSP reference>",
    "settled_amount_cents": 1599,
    "currency":            "eur"
  }
}
```

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

`order_flow.rb` in this directory is a standalone Ruby script that executes this exact flow — register → browse → place_order → sign mandates → pay — against the foodelivery demo app. It prints one JSON line on success and exits non-zero on any failure. Run it with:

```
SERVER_URL=http://127.0.0.1:3002 \
KIOSK_ISSUER=http://127.0.0.1:3002 \
bundle exec ruby order_flow.rb
```

This skill applies to any provider that exposes the Kiosk wire surface. The Actions (Step 4) and domain schema (Step 3) differ per provider; the registration, mandate structure, and pay verb are identical.
