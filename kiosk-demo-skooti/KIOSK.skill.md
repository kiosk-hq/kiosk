# Kiosk Skill — skooti scooter rental

A personal agent (Hermes, Comet, OpenClaw, a capable Siri) follows these steps
to rent a scooter from skooti — no human account, no human login, and no human
at the keyboard until the scooter is unlocked.

The human says: *"rent a scooter."* The agent does everything else.

---

## Step 1 — Discover

```
GET /.well-known/kiosk.json
```

Returns the provider's `issuer` and `endpoint`. Read `issuer` — copy it
verbatim into every mandate you sign (Step 5). `endpoint` is the base for the
REST wire calls below (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`,
`/kiosk/schema`). You browse provider data via named `query` calls
(Step 3) — never send SQL.

---

## Step 2 — Self-register (proof-of-possession handshake + Equihash PoW)

Generate an RSA-2048 keypair. Keep the private key for the session.

A public key is not a credential — prove control of the **private** key. Fetch
a single-use challenge, then sign it with `aud` set to the provider's issuer (so
the proof can't be relayed to another provider):

```http
GET /kiosk/auth/challenge?public_key=<URL-encoded PEM>
```

Returns `{ "challenge": "<nonce>" }`. Sign an RS256 JWS over
`{ "aud": "<provider issuer>", "nonce": "<challenge>", "jti": "<fresh UUID>", "iat": <now> }`
with your private key, then register:

```http
POST /kiosk/auth/register
Content-Type: application/json

{
  "public_key": "<PEM-encoded RSA public key>",
  "signed":     "<RS256 JWS over {aud, nonce, jti, iat}>"
}
```

skooti prices registration with proof-of-work: this first attempt returns
HTTP 402 with `error.code == "pow_required"` and an `error.challenges` array
(Equihash, `params: {"n": 96, "k": 5}` — solves in well under a second).
Solve EVERY challenge (see "Handling `pow_required`" below), then re-POST the
**same** register body with a top-level `pow` field. The PoP `signed` proof
is not consumed by the 402 — reuse it verbatim:

```http
POST /kiosk/auth/register
Content-Type: application/json

{
  "public_key": "<PEM-encoded RSA public key>",
  "signed":     "<same RS256 JWS as above>",
  "pow":        { "proofs": [ { "challenge": { ...echoed verbatim... },
                                "nonce": { "indices": [...], "header_nonce": 0 } } ] }
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

Store `agent_id`, `user_id`, and `access_token`. All subsequent requests carry
`Authorization: Bearer <access_token>`.

---

## Step 3 — KYC attestation

skooti requires KYC verification before allowing a rental. Submit a KYC
attestation JWS issued by the trusted KYC provider:

```http
POST /kiosk/agents/kyc
Authorization: Bearer <access_token>
Content-Type: application/json

{ "kyc_jws": "<RS256 JWS from the KYC provider>" }
```

Successful response — HTTP 200.

---

## Step 4 — Browse fleet + reserve

Browse available scooters via the named query `scooters_available`:

```http
POST /kiosk/query
Authorization: Bearer <access_token>
Content-Type: application/json

{ "name": "scooters_available" }
```

Returns a `rows` array. Pick a scooter — note its `code` (e.g. `"SK-001"`).

Reserve it:

```http
POST /kiosk/run
Authorization: Bearer <access_token>
Content-Type: application/json

{ "name": "reserve", "scooter_code": "<code>" }
```

Successful response `.value`:

```json
{
  "reservation_id":     "<uuid>",
  "scooter_code":       "SK-001",
  "price_per_min_cents": 50
}
```

Note `reservation_id` and `price_per_min_cents` — both needed for Step 5.

---

## Step 5 — Pay: sign AP2 intent + cart + payment mandates (RS256 JWS)

Payment requires three JWS tokens signed with the private key from Step 2. The
algorithm is RS256. The `iss` claim **must equal the provider's issuer** (from
`/.well-known/kiosk.json`).

### Intent mandate

```json
{
  "id":               "<fresh UUID>",
  "user_id":          "<user_id from Step 2>",
  "agent_id":         "<agent_id from Step 2>",
  "iss":              "<provider issuer>",
  "scope":            "mobility",
  "cap_amount_cents": <price_per_min_cents * 10 + 100>,
  "currency":         "eur",
  "exp":              <now + 600>,
  "iat":              <now>
}
```

### Cart mandate

```json
{
  "id":                 "<fresh UUID>",
  "intent_mandate_id":  "<id from the intent mandate above>",
  "user_id":            "<user_id from Step 2>",
  "agent_id":           "<agent_id from Step 2>",
  "iss":                "<provider issuer>",
  "line_items":         [{ "sku": "<scooter_code>", "qty": 1, "reservation_id": "<reservation_id>" }],
  "total_amount_cents": <price_per_min_cents * 1>,
  "currency":           "eur",
  "exp":                <now + 600>,
  "iat":                <now>
}
```

### Payment mandate (the assistant's funding instrument, bound to the cart)

```json
{
  "id":              "<fresh UUID>",
  "cart_mandate_id": "<id from the cart mandate above>",
  "user_id":         "<user_id from Step 2>",
  "agent_id":        "<agent_id from Step 2>",
  "iss":             "<provider issuer>",
  "payment_method":  "<PSP PaymentMethod id>",
  "amount_cents":    <total_amount_cents from the cart mandate>,
  "currency":        "eur",
  "exp":             <now + 600>,
  "iat":             <now>
}
```

`cart_mandate_id` binds the payment mandate to the cart. `amount_cents` must match the cart total exactly. The assistant presents the payment instrument; the provider charges it via its PSP.

### Pay call

```http
POST /kiosk/pay
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "intent_mandate_jws":  "<RS256 JWS of intent payload>",
  "cart_mandate_jws":    "<RS256 JWS of cart payload>",
  "payment_mandate_jws": "<RS256 JWS of payment payload>"
}
```

Successful response — HTTP 200.

---

## Step 6 — Start rental + offline unlock

Call `start_rental`. The server verifies all gates (reservation exists, KYC
cleared, payment settled) and issues a short-lived Ed25519 rental token:

```http
POST /kiosk/run
Authorization: Bearer <access_token>
Content-Type: application/json

{ "name": "start_rental", "reservation_id": "<reservation_id>" }
```

Successful response `.value`:

```json
{
  "scooter_code":  "SK-001",
  "rental_token":  "kiosk-rental-v1|SK-001|<reservation_id>|<iat>|<exp>|<jti>.<sig>",
  "exp":           1750000900
}
```

Pass `rental_token` to the App Clip via the launch URL:
```
https://skooti.app/unlock?scooter=SK-001&rt=<percent-encoded rental_token>
```

The App Clip writes the token to the scooter lock via BLE. The lock verifies
offline — no server round-trip. See `RENTAL_TOKEN.md` for the full two-token
model.

---

## Handling `pow_required`

Any wire response (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema`)
— and `/kiosk/auth/register` (Step 2) — may be HTTP 402 with
`error.code == "pow_required"` and an `error.challenges` array:

```json
{
  "ok": false,
  "error": {
    "code": "pow_required",
    "challenges": [
      { "alg": "equihash", "params": { "n": 96, "k": 5 },
        "salt": "dGVzdC1zYWx0…", "exp": 1751846400, "sig": "hmac…" }
    ]
  }
}
```

When this happens:

1. Solve EVERY challenge in the list with the reference solver
   (`solve.py` in `kiosk-pow-equihash`):
   `python3 kiosk-pow-equihash/solve.py '<challenge-json>'` →
   `{"indices": [...], "header_nonce": 0}`
2. Re-POST the **exact same** request (same path + body) with a top-level
   `pow` field. Each proof echoes its challenge back **verbatim** — it
   carries the provider's HMAC signature and is bound to this exact request:
   ```json
   { "name": "scooters_available",
     "pow":  { "proofs": [ { "challenge": { ...verbatim... },
                             "nonce": { "indices": [...], "header_nonce": 0 } } ] } }
   ```
   For a single challenge the shorthand
   `"pow": { "challenge": {…}, "nonce": {…} }` is also accepted.

Challenges expire (`exp`) and proofs are single-use — solve and retry
promptly, do not cache. Do not negotiate or downgrade the algorithm — solve
what the provider demands or tell the user to update. The provider may
challenge again on any subsequent request. skooti's demo params (n=96, k=5)
solve in well under a second; estimate cost from `params` before solving.

---

## Self-discovery

Instead of relying solely on this static file, an agent can ask the provider
for a live, machine-readable catalog of every registered query and action:

```http
GET /kiosk/schema
Authorization: Bearer <access_token>
```

Response — HTTP 200, inside `.value`:

```json
{
  "verbs":   ["query", "run", "pay", "schema"],
  "queries": [
    { "name": "scooters_available", "description": "Browse available scooters in the fleet",
                                    "params": null },
    { "name": "my_reservations",    "description": "List this principal's scooter reservations ...",
                                    "params": null }
  ],
  "actions": [
    { "name": "payment_setup", "description": "Check whether the authenticated principal has a saved payment method ...",
                               "params": {} },
    { "name": "reserve",      "description": "Reserve a scooter by its code for the authenticated principal",
                               "params": { "scooter_code": "string — scooter code, e.g. 'SK-001'" } },
    { "name": "start_rental", "description": "Verify gates (ownership, KYC, payment) and issue an Ed25519 offline rental token",
                               "params": { "reservation_id": "uuid — the reservation to activate" } }
  ]
}
```

Use `schema` to discover what is available at runtime rather than hard-coding
query or action names from this file.

---

## Rules

1. **Generate the keypair once per session; keep the private key.**
2. **Every mandate must be bound to your registered principal.** `user_id` and
   `agent_id` in both mandates must match the values from `/kiosk/auth/register`.
3. **`iss` must equal the provider's issuer.** Read it from
   `/.well-known/kiosk.json` and copy it verbatim.
4. **KYC and payment are gates.** `start_rental` returns 403 if either is
   missing — verify both steps succeed before proceeding.
5. **The rental token is a bearer credential, not an agent token.** Pass it
   to the lock via App Clip only — never include it in Kiosk API calls.
6. **Never send raw SQL.** Use named `query` calls with `body.name` + parameters.

---

## Worked example

`rental_flow.rb` in this directory is a standalone Ruby script that executes
this exact flow — register (PoW) → KYC → browse → reserve → pay → start_rental
→ LockSim offline unlock — against the skooti demo app. Run it with:

```
SERVER_URL=http://127.0.0.1:3003 \
KIOSK_ISSUER=http://127.0.0.1:3003 \
bundle exec ruby rental_flow.rb
```

This skill applies to the skooti provider. The registration PoW, KYC
requirement, and offline rental token are skooti-specific; the mandate
structure and pay verb are common Kiosk wire protocol.
