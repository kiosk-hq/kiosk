# Before and After — why an agent can't unlock a scooter, and what skooti proves

**Honesty note up front.** skooti is what a scooter-rental operator (Tier, Lime, Bird) *would* look like if it spoke Kiosk — a fake-but-realistic provider built to demonstrate the two things nobody else does for agents: **accountable registration** (proof-of-work + KYC, so a provider can drop its bot-wall for sanctioned agents without opening it to scrapers) and the **physical last-mile** (an agent pays, and the scooter unlocks itself *offline*). Nothing below implies any real operator works this way. The demo proves the *mechanism*; whether operators adopt it is an open question.

---

## Before — an agent and a physical scooter today

A personal agent can find a scooter on a map. It cannot ride one. Every operator gates the unlock behind the same wall:

- **A logged-in app session on the human's phone.** The unlock happens *inside* the operator's mobile app, authenticated to the human's account, usually after a camera/QR scan of the specific scooter. There is no sanctioned API an agent can call to release a lock.
- **An account + payment instrument the agent doesn't hold.** Registration, the stored card, and the PSD2/SCA challenge all live with the human, outside the agent's context.
- **An anti-fraud posture that treats automation as abuse.** Operators fight real scooter fraud (stolen rides, vandalism, multi-account promo abuse) with device fingerprinting and identity checks — exactly the signals agent traffic trips.

The structural result: the agent's contribution ends at *"there's a scooter 40 m away."* The human opens the app, scans, pays, and unlocks. The **last-mile — the physical act — is the wall**, and it is a harder wall than in-chat checkout because the final step is physical, not a form post.

This mirrors the discovery-only ceiling documented for in-chat commerce connectors (agents surface options, then hand back to the human to transact) — but for a scooter the handback is unavoidable today, because no operator exposes an accountable unlock path to anything but its own app.

---

## With Kiosk — skooti (`rake demo:rideflow` output)

skooti is a Rails app that speaks Kiosk. The following is a recorded no-human run — the human said *"rent a scooter"* and touched nothing until the lock opened.

```json
{"http_register":201,"http_kyc":200,"http_browse":200,"http_reserve":200,
 "http_pay":200,"http_start_rental":200,"reservation_id":"…","unlocked":true}
```

**What the agent did — no human account, no human login, no human at the keyboard:**

1. **Discover** — `GET /.well-known/kiosk.json` → skooti's issuer + endpoint.
2. **Self-register, accountably** — generated an RSA-2048 keypair and solved an **Equihash proof-of-work** (n=96, k=5) over its public key, then completed the proof-of-possession handshake — `GET /kiosk/auth/challenge` → signed the nonce → `POST /kiosk/auth/register {public_key, signed, pow}` → HTTP 201. The PoW is the "I'm not a fly-by bot" cost: cheap once for an honest client, expensive at scrape scale. No human account, no OTP, no anti-bot screen.
3. **Prove identity once** — submitted a **KYC attestation** (a signed credential from a trusted broker) → HTTP 200. Reusable across rentals; the human is never in the loop.
4. **Browse + reserve** — `query scooters_available` → picked `SK-001`; `run reserve` → a `reservation_id` with a TTL hold.
5. **Pay** — signed an AP2 intent mandate + a cart mandate (RS256 JWS, `iss` = skooti's issuer, cart `line_items` bound to the `reservation_id`), `pay` → settled.
6. **Start rental + unlock offline** — `run start_rental`; the server verified three gates (the reservation is the principal's, KYC cleared, payment settled *for this reservation*) and issued a short-lived **Ed25519 rental token** (`kiosk-rental-v1|SK-001|…|exp|jti`). The lock verified it **offline — no server round-trip** — checking the signature against a baked-in public key, the scooter code, the 15-minute expiry, and a one-shot `jti`. Lock opened.

Two things skooti does that the incumbent flow cannot:

1. **Accountability that drops the bot-wall for sanctioned agents only.** Registration PoW + KYC give the provider a real signal — a cost paid and an identity attested — so it can serve accountable agents through a structured API while keeping every anti-bot defence in place for unsanctioned traffic. Trust is then *earned by spending*: a provider can demand escalating PoW from a principal with no purchase history and little from a proven one (see the foodelivery `demo:reputation` beat). A scraper renting identities pays and pays; a real rider stops paying after the first ride.
2. **The physical last-mile, offline.** The scooter is its own trust anchor: *"someone paid skooti for ME, < 15 minutes ago, and here is the signature to prove it."* No app session, no human scan, no connectivity required at the lock. The agent pays; the scooter lets itself be ridden.

**This is a demo against a fake operator with a stub PSP and a software lock-simulator** (the firmware crypto is host-tested against the same vectors; on-device BLE on an ESP32-C3 is the remaining hardware step). The mechanism works end-to-end. Whether real operators integrate, and whether riders value an agent-driven unlock, are open questions the demo does not answer.

---

## What's needed — the provider adoption recipe

The delta between "today's scooter app" and "skooti" is a provider-side integration plus one piece of lock firmware.

**1. Add the Kiosk satellite gems** (`kiosk-core`, `kiosk-server`, plus `kiosk-pow-equihash`/`kiosk-reputation` for the bot-wall). KYC needs no extra gem in 0.1: `kiosk-server` verifies a signed `level:"verified"` attestation against a configured issuer public key (`c.kyc_public_key`); pluggable KYC-broker adapters are roadmap. In production these are versioned RubyGems; `kiosk-pay-stripe` swaps in for real payments.

**2. Run the generator** (`rails g kiosk:install`) — emits exactly two things: `config/initializers/kiosk.rb` and the nine `kiosk.*` schema migrations (agents, sessions, actions-log, reservations, device-authorizations, mandate tables, plus the KYC column); `bin/rails db:migrate` applies them. The generator does **not** touch your routes: `kiosk-server` ships the wire controllers and you mount them yourself in `config/routes.rb` — the REST verbs (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema`), the auth handshake (`/kiosk/auth/{challenge,register,login,revoke}` plus skooti's `/kiosk/agents/kyc`; `register` carries the PoW gate), and `/.well-known/kiosk.json` (inlined, built from `Kiosk.configuration`). The provider's existing Rails models are untouched.

**3. Register the rental queries + actions** — `scooters_available` / `my_reservations` (named queries, never raw SQL), `reserve` (TTL hold), and `start_rental` (the three gates: ownership + KYC + payment-settled-for-this-reservation). User-scoped queries filter by `kiosk.current_user_id()`, server-derived — never an agent parameter.

**4. Mint a rental-signing keypair + flash the locks.** Generate one Ed25519 keypair for the fleet; the **private** key signs rental tokens server-side, the **public** key is baked into every lock (one key for all locks — no per-lock secrets). The lock firmware (an ESP32-C3 reference is included: `firmware/`) verifies the token offline — signature + scooter code + expiry (needs a clock) + one-shot `jti`.

**5. Ship the App Clip / Instant App** (`appclip/`) — a passive NFC/QR tag or a pushed link launches it; it reads no agent state, only carries the short-lived rental token from the agent to the lock over BLE.

**What this does not require:** a new human-facing login, ceding the customer relationship (the mandate carries skooti's own issuer), or any change to the operator's existing app for human riders. The Kiosk surface is parallel; the bot-wall stays up for everything that hasn't paid the PoW and passed KYC.

---

*Two trust primitives are reusable beyond scooters: **PoW + reputation** (the skin-in-the-game layer KYC can't provide) and the **offline signed-capability last-mile** (any lock, gate, or pickup that must verify "this principal paid, recently" without connectivity). The scooter is just the first physical thing an agent can actually open.*
