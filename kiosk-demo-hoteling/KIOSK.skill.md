# Kiosk Skill — transact with any Kiosk provider

A personal agent (Hermes, Comet, OpenClaw, a capable Siri) follows these steps to discover, register, browse, act, and pay at any Kiosk provider — with no human account, no human login, and no human at the keyboard until the booking is complete.

The human says: *"book a hotel room in Istanbul for next month."* The agent does everything else.

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

hoteling does not require a proof-of-work or a KYC attestation to register — `POST /kiosk/agents/register` with the JSON above is sufficient.

---

## Step 3 — Browse with `query` (named, parameterized — no SQL)

The agent **never sends SQL**. Instead, call provider-registered named queries by name and pass params. hoteling exposes three queries:

### `properties` — browse the hotel catalog

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": { "name": "properties" }
}
```

Response `rows` contains `id`, `name`, `city`. Pick a property and note its `id`.

### `availability` — check room types and prices for given dates

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": {
    "name":        "availability",
    "property_id": 1,
    "check_in":    "2026-08-01",
    "check_out":   "2026-08-04"
  }
}
```

Response `rows` contains `id` (room_type_id), `name`, `nightly_price_cents` for each available room type. Pick a room type and note its `id` and `name`.

### `my_bookings` — per-user booking list (scoped to authenticated principal)

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body": { "name": "my_bookings" }
}
```

App-layer isolation is in effect: `my_bookings` scopes by `WHERE user_id = kiosk.current_user_id()` — this is the server-derived principal UUID, never an agent-supplied param. Agents cannot read other users' bookings by injecting a different user_id.

---

## Step 4 — Act with `run` (`reserve_room`)

Use the `run` command to reserve a room. Pass the property, room type, and dates from Step 3.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":         "reserve_room",
    "property_id":  1,
    "room_type_id": 2,
    "check_in":     "2026-08-01",
    "check_out":    "2026-08-04"
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "booking_id":  "<uuid>",
  "total_cents": 36000
}
```

Note `booking_id` and `total_cents` — both are required for Steps 5 and 6.

The server derives the owning user from the authenticated token (`kiosk.current_user_id()`), not from any argument. Injecting `user_id` into the request body is ignored.

---

## Step 5 — Pay: sign AP2 intent + cart + payment mandates (RS256 JWS)

Payment requires three JWS tokens signed with the private key from Step 2. The algorithm is RS256. The `iss` claim in all mandates **must equal the provider's issuer** (from `/.well-known/kiosk.json`).

### Intent mandate (spending cap)

```json
{
  "id":               "<fresh UUID>",
  "user_id":          "<user_id from Step 2>",
  "agent_id":         "<agent_id from Step 2>",
  "iss":              "<provider issuer>",
  "scope":            "lodging",
  "cap_amount_cents": <total_cents + buffer>,
  "currency":         "eur",
  "exp":              <now + 600>,
  "iat":              <now>
}
```

`cap_amount_cents` must be >= the booking total. A small buffer (e.g. +100¢) is conventional.

### Cart mandate (actual charge, bound to the intent)

```json
{
  "id":                 "<fresh UUID>",
  "intent_mandate_id":  "<id from the intent mandate above>",
  "user_id":            "<user_id from Step 2>",
  "agent_id":           "<agent_id from Step 2>",
  "iss":                "<provider issuer>",
  "line_items":         [{ "sku": "<room_type_name>", "qty": <nights>, "booking_id": "<booking_id from Step 4>" }],
  "total_amount_cents": <total_cents from Step 4>,
  "currency":           "eur",
  "exp":                <now + 600>,
  "iat":                <now>
}
```

`intent_mandate_id` binds the cart mandate to the intent cap. The `booking_id` in `line_items` is what `confirm_booking`'s payment gate checks — it must reference the exact booking being confirmed.

### Payment mandate (the assistant's funding instrument, bound to the cart)

```json
{
  "id":              "<fresh UUID>",
  "cart_mandate_id": "<id from the cart mandate above>",
  "user_id":         "<user_id from Step 2>",
  "agent_id":        "<agent_id from Step 2>",
  "iss":             "<provider issuer>",
  "payment_method":  "<PSP PaymentMethod id, e.g. pm_card_visa>",
  "amount_cents":    <total_cents from Step 4>,
  "currency":        "eur",
  "exp":             <now + 600>,
  "iat":             <now>
}
```

`cart_mandate_id` binds the payment mandate to the cart. `amount_cents` must match the cart total exactly. The assistant presents the payment instrument; the provider charges it via its PSP.

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
    "settled_amount_cents": 36000,
    "currency":             "eur"
  }
}
```

---

## Step 6 — Confirm: `run confirm_booking`

After payment is settled, confirm the booking.

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":       "confirm_booking",
    "booking_id": "<booking_id from Step 4>"
  }
}
```

Successful response — HTTP 200, inside `.value`:

```json
{
  "booking_id":        "<uuid>",
  "status":            "confirmed",
  "confirmation_code": "<uuid>"
}
```

`confirm_booking` enforces two gates server-side:
- **Gate 1 (ownership):** the booking must belong to the authenticated principal (`user_id = kiosk.current_user_id() AND status = 'reserved'`). A different principal cannot confirm your booking even if they paid for it.
- **Gate 2 (payment):** a settled payment mandate must exist whose cart `line_items` reference this `booking_id`. Calling `confirm_booking` without prior payment returns HTTP 403.

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
     "body":    { "name": "properties" },
     "pow":     { "challenge": { ...verbatim... }, "nonce": "<from solver>" } }
   ```

hoteling does not currently require PoW at registration, but any provider can add it at any time. Always handle `pow_required` gracefully.

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
    { "name": "properties",   "description": "Browse all available hotel properties", "params": null },
    { "name": "availability", "description": "Check room availability at a property for given dates",
                               "params": { "property_id": "integer — property to check",
                                           "check_in":    "date string YYYY-MM-DD",
                                           "check_out":   "date string YYYY-MM-DD" } },
    { "name": "my_bookings",  "description": "List this principal's hotel bookings (scoped to authenticated user)",
                               "params": null }
  ],
  "actions": [
    { "name": "reserve_room",    "description": "Reserve a room for the authenticated principal (creates a TTL hold)",
                                  "params": { "property_id":  "integer — property id",
                                              "room_type_id": "integer — room type id",
                                              "check_in":     "date string YYYY-MM-DD",
                                              "check_out":    "date string YYYY-MM-DD" } },
    { "name": "confirm_booking", "description": "Confirm a reserved booking (requires payment mandate referencing this booking)",
                                  "params": { "booking_id": "uuid — the booking to confirm" } }
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
7. **The `booking_id` in `line_items` must reference the booking being confirmed.** `confirm_booking` Gate-2 checks this with a jsonb-containment query.

---

## Worked example

`hoteling_flow.rb` in this directory is a standalone Ruby script that executes this exact flow — register → browse properties → check availability → reserve_room → sign mandates → pay → confirm_booking — against the hoteling demo app. It prints one JSON line on success and exits non-zero on any failure. Run it with:

```
SERVER_URL=http://127.0.0.1:3004 \
KIOSK_ISSUER=http://127.0.0.1:3004 \
bundle exec ruby hoteling_flow.rb
```

This skill applies to any provider that exposes the Kiosk wire surface. The Actions (Step 4, 6) and domain schema (Step 3) differ per provider; the registration, mandate structure, and pay verb are identical.
