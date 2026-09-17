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
| `jti` | 5 | `a3f1…` (32 hex chars) | **Single-use / replay prevention.** A unique token ID (`SecureRandom.hex(16)`). The lock records the jti on first use and rejects any second attempt within the 15-min window (in-RAM jti store, 64 entries, entries pruned after their `exp`). The shipped firmware's store does NOT survive a power cycle — making it durable is the adopter's NVS step, spelled out in `firmware/jti_store.c`. |

---

## Rental token: the exact grammar

Three programs read this token, and they are independent implementations: the
lock firmware's `skooti_verify_token` (`firmware/verify.c`, linked by
`skooti_lock.ino`), the server's `RentalTokenIssuer.verify`, and the software
lock `script/lock_sim.rb`. This section is where their grammar is DECIDED: each
reader's own header restates what that reader enforces, and a disagreement
between them is settled against this page. Three independent parsers with no
single statement of what they parse is a divergence anyone who attacks the
parse can find, and the widest of the three is the one that decides what a
fleet accepts.

What holds the readers to this page is not the page but `cd firmware && make
crosscheck`, which signs one shared vector set (`firmware/token_vectors.rb`)
with the live dev key, runs every vector through all three readers, and fails
when any reader gives an answer the set did not declare.

What holds THIS PAGE to that set is `firmware/check_grammar_coverage.rb`, which
`make crosscheck` runs beside it. Every rule below carries a
`<!-- vectors: axis -->` marker naming the axis of the set that exercises it,
and the gate reads both directions: a rule naming no axis, a rule naming an
axis the set does not have, and an axis the set has that no rule names each
fail the build. A rule that quantifies over the byte domain carries one further
condition — the axis it names is one the set runs over all 256 byte values, so
a claim about bytes the set merely samples cannot be written here at all. Its
header states the two questions it leaves open.

**Wire token**

- At most 512 bytes (`SKOOTI_TOKEN_MAX`). A longer token is refused before the
  message is parsed. <!-- vectors: length -->
- No NUL byte, anywhere in the token. The lock is handed the BLE write's bytes
  and the write's own byte count, and refuses the write when a NUL is among
  them; below that entry point every C reader takes a `const char *` and ends
  at the first NUL, so a token carrying one would be verified as the prefix
  before it while the rest of the writer's bytes — covered by no signature —
  went unread. The two Ruby readers refuse the same byte rather than reading
  past it. <!-- vectors: bytes -->
- Split at the **last** `.`: everything to its left is the signed message,
  everything to its right is the signature. No `.` at all is a refusal.
  Neither half may be empty. <!-- vectors: wire -->
- The signature is base64url over the alphabet `A-Za-z0-9-_`, **unpadded**, at
  most 88 characters, and must decode to exactly 64 bytes — the Ed25519
  signature over the message bytes. <!-- vectors: sig -->
- One signature has one spelling. The 86 characters a 64-byte signature encodes
  to carry four trailing bits that decode to nothing, and a canonical encoding
  leaves those bits zero — so of the sixteen strings that decode to a given
  signature exactly one is accepted and the other fifteen are refused, as are
  `=` padding and the standard alphabet's `+` and `/`, which are the two
  spellings a permissive base64 helper takes without being
  asked. <!-- vectors: sig -->
- The second half of those 64 bytes is a scalar, and it is below the Ed25519
  group order — the range RFC 8032 5.1.7 decodes it in. Multiplying the base
  point by the group order gives the identity, so a signature and that same
  signature with the group order added to its scalar satisfy one verification
  equation: a second 64 bytes over the same message under the same key, which
  no rule about ENCODING can tell apart from the first. The server and the
  software lock verify through OpenSSL, which applies the range check; the lock
  firmware applies it itself, in constant time, before it hands the bytes to
  its vendored verifier, whose own bound stops at 2 to the 253 and leaves
  exactly that one multiple inside. This says which 64 bytes are a signature,
  not what a signature proves. <!-- vectors: sig -->
- **The answer is a function of the token's BYTES, and of nothing else.** A
  Ruby String carries an encoding tag its caller chose, and `rindex`, `split`,
  `match?` and `==` all consult it; the lock is a C program that has no such
  thing. So both Ruby readers convert with `String#b` before they parse, which
  never raises and never changes a byte, and the verdict they reach is the
  verdict the lock reaches on the same buffer. Six tags over the same token are in
  the vector set, one of them the tag on which a reader that skipped the
  conversion would raise rather than answer at all. <!-- vectors: encoding -->

**Message**

- Exactly six pipe-separated fields, which is exactly five `|` bytes. <!-- count: 6 ¦ from: sed -n 's/.*FIELD_COUNT = //p' kiosk-demo-skooti/app/services/rental_token_issuer.rb --> <!-- vectors: count -->
- **No field may be empty**, and no field may contain `|`. <!-- vectors: empty -->
- **A trailing `|` is another field, not punctuation.** `kiosk-rental-v1|…|<jti>|`
  is a seven-field message and is refused. That deserves saying out loud
  because Ruby's `String#split("|")` silently DROPS trailing empty fields, so a
  reader written as `message.split("|").length == 6` sees six where the C
  parser, walking the pipes, sees seven. Both Ruby readers here split with a
  negative limit for exactly that reason. <!-- vectors: count -->

**Fields**

| # | Field | What is accepted |
|---|---|---|
| 0 | tag | the bytes `kiosk-rental-v1` and nothing else, compared in constant time <!-- vectors: tag --> |
| 1 | `scooter_code` | 1 or more characters of `A-Za-z0-9-._~`; every other byte value is refused. The lock additionally requires it to equal its own provisioned code; `RentalTokenIssuer.verify` is not a lock and has no code to compare against, so the charset is the whole of what holds this field there. <!-- vectors: charset, empty --> |
| 2 | `reservation_id` | 1 or more characters of `A-Za-z0-9-._~` — the RFC 3986 unreserved set, which is what a canonical uuid is spelled with and what survives the App Clip launch URL unchanged. Every other byte value is refused, a newline, a tab, a control character and multibyte UTF-8 among them. No reader gates on this field's VALUE; all three hold its charset. <!-- vectors: charset --> |
| 3 | `iat` | 1 to 20 ASCII digits `0`–`9`, value at most 2^64−1. No sign, no `_` separators, no surrounding whitespace, no `0x`. No reader gates on `iat` — `exp` alone bounds the window — but all three hold it to the grammar, because a field nobody parses is a field each reader may read differently. <!-- vectors: int --> |
| 4 | `exp` | the same syntax as `iat`. The window is then `now < exp`: a lock accepts while its clock is still behind `exp` and refuses at the instant `exp` names, so the last live second is `exp - 1`. <!-- vectors: int, fresh --> |
| 5 | `jti` | exactly 32 lowercase hex characters `[0-9a-f]`, which is what `SecureRandom.hex(16)` mints. It is the key the replay store is written under, so a reader that returned success on other bytes would be handing that store a key it refuses. <!-- vectors: jti --> |

Most of the fields are narrower than the obvious parse in the language each
reader is written in, and that is deliberate. Ruby's `Integer(s, 10)` reads
`+1750000900`, `1_750_000_900` and `" 1750000900"`; `Base64.urlsafe_decode64`
translates `-_` to `+/` and pads a short input before decoding; a Ruby String
holds any byte at all and carries a tag that decides what the operations on it
mean. Between them those read spellings the firmware's `parse_uint64`,
character table and byte buffer read none of. Where two readers of one
credential differ, the WIDEST is the one that decides what a fleet accepts, so
the narrow reading is the contract — and which reader is widest varies by axis,
measured rather than assumed: on the integer syntax and the base64 alphabet the
Ruby pair was wider, on the base64 tail and on a byte no UTF-8 decoder accepts
the physical lock was, which is the direction nothing downstream can catch.

The opaque fields are a CHARSET rather than "any bytes but the delimiter" for
the same reason, and it is the one that took three attempts to see. A
domain of 254 values per position cannot be enumerated, so a sentence about it
can only ever be sampled by a vector set, and a sampled axis is
indistinguishable on this page from an exhausted one. A set of 66 characters can be written down: the
shared set carries one vector for every byte value in `reservation_id` and for
every value outside the set in `scooter_code`, so the rows above are held by a
measurement over the whole domain instead of by a promise about it.

**What this section does not claim**

- That the three readers are one program. They are separate implementations in
  two languages, which is what makes the crosscheck worth running and what
  guarantees they can drift again.
- That this page is complete. It is the statement of what has been written
  down; a property of the token nobody has written down is invisible to it and
  to the vector set alike, and the only thing that has ever found one is
  somebody attacking the parse.
- Anything about the `scooter_code` charset as an ACCEPT. Field 1 has to equal
  the lock's own provisioned code, so the only value the two locks take is
  `SK-001` itself — an in-charset byte put into it is taken by the server's
  verifier, which has no code to compare against, and turned away by both
  locks. That asymmetry is by design and is not a disagreement about grammar.
- Anything about signature FORGERY. Every vector in the shared set carries a
  genuine signature over its own message; a flipped byte, a signature over
  other bytes, a wrong key and a LOW-ORDER key under which a signature nobody
  produced verifies are `firmware/host_test.c`'s subject and the KAT's. The
  scalar rule above starts from a signature somebody already made and narrows
  how it may be spelled, so it is on this side of that line too.
- That the vendored Ed25519 verifier is RFC 8032 strict in every other
  respect. Measured at head, two of the decoder's rules are the library's
  rather than the RFC's: a public key whose y coordinate is at or above the
  field prime is reduced instead of refused, and the x = 0 encoding is taken
  with either sign bit. Both are about the PUBLIC KEY, which this lock is given
  once at provisioning and never reads off the wire. The C reader applies both
  rules itself before it calls the library, so on those two its answer is the
  RFC's. It goes one step FURTHER than the RFC on a third: a low-order public
  key is a canonical encoding the RFC permits, but under it a signature nobody
  produced verifies (R = [1]B, S = 1, jti ground so the cofactor term
  vanishes), so the C reader refuses the eight small-order encodings — the
  policy libsodium enforces, stricter than RFC 8032. This is not a claim that
  the crypto is otherwise complete: it is the statement of which public keys
  this reader turns away and why. The library beside it is unchanged, and an
  adopter who calls it directly inherits neither the two rules nor the
  refusal. The two Ruby readers are not asked: their key is a constant of the
  server, the shared vectors vary the TOKEN, and nothing in this set carries a
  key at all. What holds the C answer is `firmware/host_test.c`.
- That the readers agree on TIMING. The C reader compares the tag and the
  scooter code in constant time; the two Ruby readers use `==`. An accept-or-
  refuse answer is all a vector carries, so nothing here measures it.
- Anything about replay. The consumed-jti set is per-reader state rather than a
  property of the token.

---

## Issuance and handoff flow

```
Assistant (agent token → Kiosk API)
  │
  ├─ reserve(scooter_code)          → reservation_id
  ├─ pay(reservation_id)            → payment mandate settled
  │
  └─ start_rental(reservation_id)
       │
       Gate 1:  reservation exists, belongs to this principal, status = 'reserved'
       Gate 1b: the reserved vehicle is licence-FREE — a motorcycle
                is refused here and goes through rent_motorcycle, whose Gate 0
                is the KYC one. start_rental has NO KYC gate.
       Gate 2:  settled payment (settlement record) references THIS reservation_id
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
    https://skooti.demo.kiosk.tech/unlock?scooter=SK-001&rt=<percent-encoded token>
       │
       ▼
  App Clip launches (NFC / QR / push)
    Parses scooter= and rt= from URL
    BLE scan → connect to skooti-SK-001
    Writes rental token (UTF-8) to Unlock characteristic
       │
       ▼
  Lock verifies offline:
    1. Wire token is at most 512 bytes
    2. Split on last '.' → message + sig
    3. Base64url-decode sig (must be 64 bytes)
    3b. Its scalar half is below the group order (RFC 8032 5.1.7)
    4. Ed25519-verify sig over message bytes with provisioned pubkey
    5. Parse the pipe-fields; require exactly six, none of them empty
    6. field[0] == "kiosk-rental-v1"  (domain-separation tag)
    7. field[1] == own SCOOTER_CODE
    8. field[3] (iat) and field[4] (exp) are 1-20 plain digits
    9. field[4] (exp) > now
   10. field[5] (jti) is 32 lowercase hex
   11. jti_seen_or_insert(jti, exp, now) == 0  (not a replay)
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
