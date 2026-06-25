# The two-token model

The skooti unlock flow uses two distinct tokens that never cross roles.

## Agent token vs. rental token

| | Agent token | Rental token |
|---|---|---|
| **What it is** | RS256 JWT issued by the Kiosk authorization server | Ed25519 capability issued by the skooti provider |
| **Who holds it** | The AI assistant (running the rental flow) | The assistant → passes it to the App Clip → App Clip writes it to the lock |
| **Where it goes** | `Authorization: Bearer` header on every Kiosk API call | BLE write to the lock's Unlock characteristic — never sent back to the Kiosk API |
| **Lifetime** | Longer-lived, reusable across multiple API calls | Single-use, ≤ 15 min (`exp = iat + 900`) |
| **Verified by** | Kiosk server (online) | The scooter lock, offline — no server round-trip at unlock time |
| **Key type** | RSA (RS256) | Ed25519 (provider signing key) |

The lock holds only the skooti Ed25519 public key. It never sees the agent JWT, and the Kiosk API never sees the rental token.

---

## Rental token: field-by-field

**Wire format** (split on the last `.`):

```
kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(Ed25519 sig)>
```

The left side (everything before the last `.`) is the signed message — UTF-8 bytes over which the Ed25519 signature is computed. The right side is the 64-byte Ed25519 signature, base64url-encoded without padding.

| Field | Index | Example | Why it exists |
|---|---|---|---|
| `kiosk-rental-v1` | 0 | `kiosk-rental-v1` | **Domain-separation tag.** The lock accepts a token ONLY if field 0 equals this exact string. This prevents the skooti signing key from being cross-used to mint any other credential the lock would honor. It also makes the token self-documenting — it is unambiguously a rental capability, never confusable with the agent JWT or any other signed artifact. |
| `scooter_code` | 1 | `SK-001` | **Scooter binding.** The lock checks this against its own provisioned code. A token for `SK-001` cannot unlock `SK-002`. Critically, the server derives `scooter_code` from the reservation row — the client cannot supply a different code. |
| `reservation_id` | 2 | `550e8400-…` | **Reservation binding.** Ties the token to a specific reservation so the issued capability is auditable and scope-limited to one trip. |
| `iat` | 3 | `1750000000` | Unix issue timestamp (decimal seconds). Together with `exp`, establishes the token's validity window. |
| `exp` | 4 | `1750000900` | **Bounded window.** `exp = iat + 900` (15 min). The lock checks `exp > now` before accepting. Limits how long a captured token remains usable. |
| `jti` | 5 | `a3f1…` (32 hex chars) | **Single-use / replay prevention.** A unique token ID (`SecureRandom.hex(16)`). The lock records the jti on first use and rejects any second attempt — even within the 15-min window and even across a lock reboot (NVS-backed jti store, 64 entries, entries pruned after their `exp`). |

---

## Issuance and handoff flow

```
Assistant (agent token → Kiosk API)
  │
  ├─ reserve(scooter_code)          → reservation_id
  ├─ kyc_verify(...)                → KYC gate clears
  ├─ pay(reservation_id)            → payment mandate settled
  │
  └─ start_rental(reservation_id)
       │
       Gate 1: reservation exists, belongs to this principal, status = 'reserved'
       Gate 2: agent is KYC-verified (kyc_verified_at NOT NULL)
       Gate 3: settled payment mandate references THIS reservation_id
       │
       All gates pass →
         scooter_code derived server-side from reservation FK (not from client)
         RentalTokenIssuer.issue(scooter_code, reservation_id, now, ttl: 900)
         reservation status → 'active'
       │
       Returns: { scooter_code:, rental_token:, exp: }
       │
       ▼
  Assistant puts rental_token into App Clip launch URL:
    https://skooti.app/unlock?scooter=SK-001&rt=<percent-encoded token>
       │
       ▼
  App Clip launches (NFC / QR / push)
    Parses scooter= and rt= from URL
    BLE scan → connect to skooti-SK-001
    Writes rental token (UTF-8) to Unlock characteristic
       │
       ▼
  Lock verifies offline:
    1. Split on last '.' → message + sig
    2. Base64url-decode sig (must be 64 bytes)
    3. Ed25519-verify sig over message bytes with provisioned pubkey
    4. Parse 6 pipe-fields; require exactly 6
    5. field[0] == "kiosk-rental-v1"  (domain-separation tag)
    6. field[1] == own SCOOTER_CODE
    7. field[4] (exp) > now
    8. jti_seen_or_insert(jti, exp, now) == 0  (not a replay)
    All pass → GPIO HIGH 3 s → scooter unlocked
```

The rental token is **never sent back to the Kiosk API**. The lock **never calls the server**. Revocation within the 15-min window is not supported; the short TTL and single-use constraint are the primary controls.

---

## Honest residuals

The rental token is a **bearer capability**: any party that holds the wire token string can present it to the correct lock within the 15-min window (before first use). Mitigations in place:

- **Single scooter** — the token is bound to one scooter code; it cannot unlock any other.
- **≤ 15 min** — the window closes quickly.
- **Single-use** — the lock rejects the token after first use, so intercepting a token that has already been used gives nothing.

What is not yet in place: the token is not bound to the device or principal that requested it. A production deployment may add device attestation (e.g., bind the token to the App Clip installation's device key) or deliver it via a Shared App Group Keychain rather than a URL parameter, reducing exposure further.
