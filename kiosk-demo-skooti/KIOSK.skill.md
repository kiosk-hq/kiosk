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
verbatim into every mandate you sign (Step 5). `endpoint` is where you send all
`/kiosk/exec` calls below. You browse provider data via named `query` calls
(Step 3) — never send SQL.

---

## Step 2 — Self-register (SHA256 PoW at registration)

Generate an RSA-2048 keypair. Keep the private key for the session.

The skooti registration endpoint requires a SHA256 leading-zero PoW over the
public key (difficulty 20). Find the smallest nonce `n ≥ 0` such that
`SHA256("<public_key_pem>.<n>")` has ≥ 20 leading zero bits, then include it as
`pow`:

```http
POST /kiosk/agents/register
Content-Type: application/json

{
  "name":       "hermes",
  "public_key": "<PEM-encoded RSA public key>",
  "role":       "customer",
  "pow":        "<solved nonce string>"
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
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "query",
  "body":    { "name": "scooters_available" }
}
```

Returns a `rows` array. Pick a scooter — note its `code` (e.g. `"SK-001"`).

Reserve it:

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body":    { "name": "reserve", "scooter_code": "<code>" }
}
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

## Step 5 — Pay: sign AP2 intent + cart mandates (RS256 JWS)

Payment requires two JWS tokens signed with the private key from Step 2. The
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

Successful response — HTTP 200.

---

## Step 6 — Start rental + offline unlock

Call `start_rental`. The server verifies all gates (reservation exists, KYC
cleared, payment settled) and issues a short-lived Ed25519 rental token:

```http
POST /kiosk/exec
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "command": "run",
  "body":    { "name": "start_rental", "reservation_id": "<reservation_id>" }
}
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

Any `/kiosk/exec` response may be HTTP 402 with `error.code == "pow_required"`.
When this happens, solve the challenge and retry — the full protocol is
documented in `kiosk-pow/SKILL.md`. Summary:

1. Install once: `pip install argon2-cffi`
2. Solve: `python3 kiosk-pow/solve.py '<challenge-json>'` → reads `{"nonce": "..."}`
3. Re-POST the **exact same** request body with a top-level `pow` field:
   ```json
   { "command": "query",
     "body":    { "name": "scooters_available" },
     "pow":     { "challenge": { ...verbatim... }, "nonce": "<from solver>" } }
   ```

Do not negotiate or downgrade the algorithm — solve what the provider demands
or tell the user to update. The provider may challenge again on any subsequent
request. The reference solver is `kiosk-pow/solve.py`.

Note: the SHA256 PoW at registration (Step 2) is a different, simpler
mechanism solved inline — it is not the Argon2id `pow_required` exec protocol.

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
    { "name": "scooters_available", "description": "Browse available scooters in the fleet",
                                    "params": null },
    { "name": "my_reservations",    "description": "List this principal's scooter reservations ...",
                                    "params": null }
  ],
  "actions": [
    { "name": "reserve",      "description": "Reserve a scooter by its code for the authenticated principal",
                               "params": { "scooter_code": "string — scooter code, e.g. 'SK-001'" } },
    { "name": "start_rental", "description": "Verify gates (ownership, KYC, payment) and issue an Ed25519 offline rental token",
                               "params": { "reservation_id": "uuid — the reservation to activate" } }
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

1. **Generate the keypair once per session; keep the private key.**
2. **Every mandate must be bound to your registered principal.** `user_id` and
   `agent_id` in both mandates must match the values from `/kiosk/agents/register`.
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
