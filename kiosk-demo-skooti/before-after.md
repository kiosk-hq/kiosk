# Before and After — why an AI assistant can't unlock a scooter, and what skooti proves

**Honesty note up front.** skooti is what a scooter-rental operator (Tier, Lime, Bird) *would* look like if it spoke Kiosk — a fake-but-realistic operator built to demonstrate the two things nobody else does for AI assistants: **accountable registration** (an Equihash proof-of-work, so an operator can drop its bot-wall for sanctioned AI assistants without opening it to scrapers) and the **physical last-mile** (an AI assistant pays, and the scooter unlocks itself *offline*). Registration has exactly ONE gate and it is the PoW — no identity check is involved in getting an account here. skooti also ships a signed **KYC attestation**, but it gates one verb, `rent_motorcycle`, where a licence is the point; a scooter rents on ownership and payment alone. Nothing below implies any real operator works this way. The demo proves the *mechanism*; whether operators adopt it is an open question.

---

## Before — an AI assistant and a physical scooter today

A personal AI assistant can find a scooter on a map. It cannot ride one. Every operator gates the unlock behind the same wall:

- **A logged-in app session on the human's phone.** The unlock happens *inside* the operator's mobile app, authenticated to the human's account, usually after a camera/QR scan of the specific scooter. There is no sanctioned API an AI assistant can call to release a lock.
- **An account + payment instrument the AI assistant doesn't hold.** Registration, the stored card, and the PSD2/SCA challenge all live with the human, outside the AI assistant's context.
- **An anti-fraud posture that treats automation as abuse.** Operators fight real scooter fraud (stolen rides, vandalism, multi-account promo abuse) with device fingerprinting and identity checks — exactly the signals AI-assistant traffic trips.

The structural result: the AI assistant's contribution ends at *"there's a scooter 40 m away."* The human opens the app, scans, pays, and unlocks. The **last-mile — the physical act — is the wall**, and it is a harder wall than in-chat checkout because the final step is physical, not a form post.

This mirrors the discovery-only ceiling documented for in-chat commerce connectors (AI assistants surface options, then hand back to the human to transact) — but for a scooter the handback is unavoidable today, because no operator exposes an accountable unlock path to anything but its own app.

---

## With Kiosk — skooti (`rake demo:rideflow` output)

skooti is a Rails app that speaks Kiosk. Below is the RUN 1 section of a
`rake demo:rideflow` recording — **2026-08-26**, against a booted demo.
`bin/check-demo-derivations` holds every line in it to a string literal one of
the declared producers prints; that is a subset test, so what was taken off the
top and the bottom is the `abridged:` field's claim and a human's signature,
not this script's. The human said *"rent a scooter"* and touched nothing until
the lock opened. The task runs four further beats this
excerpt leaves out: RUN 2 skips the payment and asks for the same unlock, which
the server refuses `403` — that is what makes RUN 1's `200` mean something; RUN 3
pins the two query verbs; then a structure check that no ROW LEVEL SECURITY is
in play on this demo's own tables — read off the generated `db/structure.sql`,
which is what that beat's own output names — and the capture-anchored paid-state
regression (K-853), which does run against the database.

<!-- derived: transcript | task: bundle exec rake demo:rideflow | from: lib/tasks/demo.rake, script/rental_flow.rb, script/equihash_register.rb, script/lock_sim.rb | keys_from: app/controllers/kiosk/fleet_controller.rb, app/controllers/kiosk/rentals_controller.rb | abridged: above the first line quoted, the /etc/hosts hint the task prints when the demo host does not resolve; below the last, RUN 2 (the SKIP_PAY 403), RUN 3 (the query verbs), the structure check, the capture-anchored paid-state run, and the Assertions banner with its All assertions passed. line -->
```
══ RUN 1: Happy path ══
  Server up at http://127.0.0.1:3004
  Registering (solving 1 Equihash PoW)...
  Registered.
  Browsed fleet: 6 scooter(s) available, picking SK-001
  Reserved: id=ae01a0ae-336f-494f-b226-a006baee0947 scooter=SK-001 price=€0.15/min
  Payment settled: settlement_id=95891ed3-c67e-4a0c-be61-24a687ce0dd7
  start_rental: scooter=SK-001 exp=1787765706 unlocked=true
{"http_register":201,"http_browse":200,"http_reserve":200,"http_pay":200,"http_start_rental":200,"user_id":"1b9a71a1-48f3-4b9d-98f1-8e6c911f1fdc","agent_id":"f74e9ef5-46f5-4c7d-80c5-cd35897c3395","reservation_id":"ae01a0ae-336f-494f-b226-a006baee0947","browse_rows_count":6,"rental_token":"kiosk-rental-v1|SK-001|ae01a0ae-336f-494f-b226-a006baee0947|1787764806|1787765706|c1f7e137a0e85cf3a72aec81ec064645.FgmXiTXn7PdxBl2MoKSFpEXWyIx3E6ylnVch7P8FjrTN1ErKLAw6ciC-SFEriWZodu6N_z6EVIOENFSkzx4DCw","exp":1787765706,"unlocked":true}
  OK  http_browse (query scooters_available) == 200
  OK  browse_rows_count >= 1 (got 6)
  OK  http_start_rental == 200
  OK  unlocked == true
  OK  rental_token present (kiosk-rental-v1|SK-001|ae01a0a...)
  OK  exp present (1787765706)
  OK  this run's reservation is active in the DB (id=ae01a0ae-336f-494f-b226-a006baee0947)
  OK  exactly one kiosk.settlements row for this run's principal (1b9a71a1-48f3-4b9d-98f1-8e6c911f1fdc)

  -- Offline-token negatives --
  OK  N1 expired: unlock(now=exp+1) == false
  OK  N2 wrong-scooter: unlock(SK-999) == false
  OK  N3 forged-sig: unlock(flipped sig) == false
  OK  N4 replay-jti: first=true, second=false
  Server stopped.
```

**What the AI assistant did — no human account, no human login, no human at the keyboard:**

1. **Discover** — `GET /.well-known/kiosk.json` → skooti's issuer + endpoint.
2. **Self-register, accountably — proof of possession FIRST, then the toll.** The order matters, because an assistant cannot solve anything in advance: the work it must do does not exist until the server hands it out. Generated an RSA-2048 keypair, then `GET /kiosk/auth/challenge?public_key=<urlencoded pem>` (the query parameter is REQUIRED — without it the endpoint answers `400 missing public_key query parameter`) → signed the nonce → `POST /kiosk/auth/register {public_key, signed}` → **HTTP 402**, an RFC 9457 problem document whose top-level `challenges` member carries the SERVER-minted Equihash challenges. Only then does the client solve them, and re-POST the SAME signed body with the proofs in the `Kiosk-PoW` request header → HTTP 201. (The PoP nonce survives the 402, because the toll gate runs before the challenge is spent.) The operator picks its cost with the `KIOSK_POW_DIFFICULTY` knob; skooti ships the `low` setting, lighter than the bundled solver's own default, so a demo run solves in well under a second — which is the line `Registering (solving 1 Equihash PoW)...` in the transcript above. The PoW is the "I'm not a fly-by bot" cost: cheap once for an honest client, expensive at scrape scale. No human account, no OTP, no anti-bot screen. `script/equihash_register.rb` is those thirty lines.
3. **No identity check — a scooter needs none.** The flow submits no KYC at all: a licence-free scooter rents on ownership + payment alone, which is why no `http_kyc` appears in the transcript above. The signed **KYC attestation** (a credential from a trusted broker, verified against the operator's configured `c.kyc_public_key`) gates the combustion motorcycle instead — `rent_motorcycle`, driven by `rake demo:kyc` / `script/kyc_flow.rb`. It is submitted once and reusable across rentals; the human is never in the loop.
4. **Browse + reserve** — `GET /kiosk/scooters_available` → picked `SK-001`; `POST /kiosk/reserve` → a `reservation_id`. The hold has no expiry — it stays until `start_rental` flips it to `active`.
5. **Pay** — signed all **three** AP2 mandates and sent them together: an intent mandate, a cart mandate (`line_items` bound to the `reservation_id`, tied to the intent by `intent_mandate_id`) and a payment mandate (tied to the cart by `cart_mandate_id`) — RS256 JWS, `iss` = skooti's issuer — then `POST /kiosk/pay {intent_mandate_jws, cart_mandate_jws, payment_mandate_jws}` → settled. All three are REQUIRED: the engine refuses a chain missing any one of them with a typed `400 args.<name>_jws required` before anything is charged.
6. **Start rental + unlock offline** — `POST /kiosk/start_rental`; the server verified three gates (the reservation is the principal's and still reserved, the vehicle is licence-free, payment settled *for this reservation*) and issued a short-lived **Ed25519 rental token** (`kiosk-rental-v1|SK-001|…|exp|jti`). The lock verified it **offline — no server round-trip** — checking, in this order, the **domain-separation tag** (`firmware/verify.c`'s Gate 0: the token must begin `kiosk-rental-v1`, compared in constant time, so a token signed with this key for any other purpose is rejected before a single claim is acted on), the signature against a baked-in public key, the scooter code, the 15-minute expiry, and a one-shot `jti`. Lock opened.

Two things skooti does that the incumbent flow cannot:

1. **Accountability that drops the bot-wall for sanctioned AI assistants only.** The registration PoW gives the operator a real signal — a cost paid — so it can serve accountable AI assistants through a structured API while keeping every anti-bot defence in place for unsanctioned traffic; and where a licence genuinely matters, the KYC attestation adds a second, verb-level signal (`rent_motorcycle`) without touching the account gate. Trust is then *earned by spending*: an operator can demand escalating PoW from a principal with no history and little from a proven one (see the atablefor `demo:reputation` beat). A scraper renting identities pays and pays; a real rider stops paying after the first ride.
2. **The physical last-mile, offline.** The scooter is its own trust anchor: *"someone paid skooti for ME, < 15 minutes ago, and here is the signature to prove it."* No app session, no human scan, no connectivity required at the lock. The AI assistant pays; the scooter lets itself be ridden.

**This is a demo against a fake operator with a stub PSP and a software lock-simulator** (the firmware crypto is host-tested against the same vectors; on-device BLE on an ESP32-C3 is the remaining hardware step). The mechanism works end-to-end. Whether real operators integrate, and whether riders value an AI-assistant-driven unlock, are open questions the demo does not answer.

---

## What's needed — the operator adoption recipe

The delta between "today's scooter app" and "skooti" is an operator-side integration plus one piece of lock firmware.

**1. Add the Kiosk satellite gems.** The minimum is `kiosk-core` + `kiosk-server` (the engine) plus `kiosk-pow-equihash`/`kiosk-reputation` for the bot-wall. This demo's `Gemfile` carries nine — those four, plus `kiosk-all`, `kiosk-rls` (the optional Postgres backstop), `kiosk-pay-stripe`, `kiosk-redteam` (the adversarial battery) and `kiosk-user-idp-devise` (the human-session channel) — and `json_schemer`, which `kiosk-server` needs only because this origin turns `c.validate_requests` on. KYC needs no extra gem: `kiosk-server` verifies a signed `level:"verified"` attestation against a configured issuer public key (`c.kyc_public_key`); pluggable KYC-broker adapters are roadmap. In production these are versioned RubyGems.

**2. Run the generator** (`rails g kiosk:install`) — emits exactly two things: `config/initializers/kiosk.rb` and the `kiosk.*` schema migrations (the namespace itself, the identity tables — `agents`, `agent_tokens`, `agent_mappings` — `reservations`, `device_authorizations`, the AP2 mandate trail and `kyc_attributes`); `bin/rails db:migrate` applies them. The generator does **not** touch your routes: `kiosk-server` ships the wire controllers and you mount them yourself in `config/routes.rb` — see that file for the whole table, which is longer than it looks. **Every controller in it is kiosk-server's**, including `/.well-known/kiosk.json` (`kiosk/server/discovery#kiosk_json`), the rest of the discovery surface (`/agents.txt`, `/agents.json`, `/.well-known/agent-configuration`, `/.well-known/api-catalog`, `/auth.md`, `/kiosk/openapi.json`, `/kiosk/.well-known/jwks.json`), the auth handshake (`/kiosk/auth/{challenge,register,login,revoke,link,claim,unlink}` — `register` is where the PoW gate bites) and the KYC attestation endpoint `/kiosk/agents/kyc` (`kiosk/server/kyc_attestation#create` — skooti routes it, it does not implement it), the RFC 8628 device-grant pair, `/kiosk/pay` and `/kiosk/schema`, and finally the per-verb pair drawn LAST so nothing an operator declares can shadow the reserved lines. Mounting the engine would draw all of it in one line; skooti hand-draws it so an adopter can see what the mount installs. Nothing in your database schema changes: the gems live in their own `kiosk.*` namespace. Your MODELS do get a little Kiosk in them — `owned_by_current_principal`, the one place the `kiosk.current_user_id()` predicate is written, is a scope on skooti's own `Reservation` and `KycVerificationRequest` — but it is a few lines, adds no column, and is the sort of thing you would write to expose a model over any API.

**3. Declare the rental verbs in two ordinary Rails controllers** — `app/controllers/kiosk/fleet_controller.rb` (`include Kiosk::Handler`, each declaration marked `kind :query`) carries the three queries `scooters_available` / `my_reservations` / `kyc_status`; `app/controllers/kiosk/rentals_controller.rb` (same mixin, `kind :action`) carries the five actions `reserve` (a hold with no expiry — it stays until `start_rental` flips it to `active`), `payment_setup`, `request_kyc`, `start_rental` and `rent_motorcycle`. Both classes are named in `c.handlers`; the initializer holds configuration, not verbs. `start_rental` issues the unlock token for a LICENCE-FREE scooter behind three gates — (1) the reservation is the caller's own and still `reserved`, (1b) the reserved vehicle is licence-free, so a needs-licence motorcycle is refused here and sent to `rent_motorcycle`, and (2) the caller has a settled payment for THIS reservation. There is deliberately NO KYC gate on `start_rental`: a scooter needs no licence, so the attestation is `rent_motorcycle`'s gate rather than this one. Queries are named queries, never raw SQL, and the user-scoped ones filter by `kiosk.current_user_id()`, server-derived — never an AI-assistant parameter.

**4. Mint a rental-signing keypair + flash the locks.** Generate one Ed25519 keypair for the fleet; the **private** key signs rental tokens server-side, the **public** key is baked into every lock (one key for all locks — no per-lock secrets). The lock firmware (an ESP32-C3 reference is included: `firmware/`) verifies the token offline — domain-separation tag (`kiosk-rental-v1`, `verify.c`'s Gate 0, constant-time) + signature + scooter code + expiry (needs a clock) + one-shot `jti`.

**5. Ship the App Clip** (`appclip/`) — a passive NFC/QR tag or a pushed link launches it; it reads no AI-assistant state, only carries the short-lived rental token from the AI assistant to the lock over BLE. What ships here is iOS only, and it is the SOURCES rather than an Xcode project: the App Clip and container Swift targets (`SkootiClip/`, `Skooti/`), the XcodeGen spec `project.yml` and a `Makefile`. `make project` GENERATES `SkootiDemo.xcodeproj` from `project.yml`; the generated project is gitignored and this repo carries no `.xcodeproj` at all. The Android equivalent is an Instant App, and it is not written — nothing in this repo builds one.

**What this does not require:** a new human-facing login, ceding the customer relationship (the mandate carries skooti's own issuer), or any change to the operator's existing app for human riders. The Kiosk surface is parallel; the bot-wall stays up for everything that has not paid the registration PoW.

---

*Two trust primitives are reusable beyond scooters: **PoW + reputation** (the skin-in-the-game layer KYC can't provide) and the **offline signed-capability last-mile** (any lock, gate, or pickup that must verify "this principal paid, recently" without connectivity). The scooter is just the first physical thing an AI assistant can actually open.*
