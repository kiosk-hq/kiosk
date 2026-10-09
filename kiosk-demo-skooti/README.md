# kiosk-demo-skooti

Scooter rental demo operator for Kiosk.

`skooti` is a fake-but-realistic micromobility operator that rents scooters —
and a KYC-gated combustion motorcycle — over the Kiosk wire. An AI assistant
self-registers, reserves a vehicle and pays for it with no account of its
human's and no sign-in anywhere, and comes away with a short-lived signed
token that opens that one vehicle. The last step is the human's, because it is
physical: they present the token at the scooter — a tap on its NFC tag or a
scan of its QR opens the App Clip, which writes the token to the lock over
Bluetooth. Payment is kiosk-pay-stripe in Stripe test mode; the tasks and CI
charge a local stripe-mock. The lock verifies the offline
Ed25519 token by itself, with no server round-trip; here it is a software
simulation of the firmware in `firmware/`.

## Wire surface

One endpoint per verb: a read is a `GET` at its own name with arguments in the
query string, a write is a `POST` at its own name with a JSON body. Success is
the handler's payload with no envelope around it (a query always answers an
array); a refusal is an RFC 9457 problem document whose `code` is a flat
member. A path that names no registered verb draws no route at all, so it is
the ordinary 404 any undrawn path gets — bearer or not, because a routing miss
is decided before any credential is read.

| Endpoint | Verb | What it does |
|---|---|---|
| `GET /kiosk/scooters_available` | `scooters_available` | Browse the fleet (scooters + motorcycles); `needs_licence` flags the KYC-gated combustion vehicles |
| `GET /kiosk/my_reservations` | `my_reservations` | This principal's reservations (owner-scoped) |
| `POST /kiosk/reserve` | `reserve(scooter_code)` | Reserve a vehicle by its code (inserts a `status='reserved'` row; the hold has no expiry/TTL — it stays until `start_rental` flips it to `active`) |
| `POST /kiosk/payment_setup` | `payment_setup` | Check whether the principal has a saved payment method (served by kiosk-server) |
| `POST /kiosk/start_rental` | `start_rental(reservation_id)` | Verify three gates (ownership, the vehicle being licence-free, and a settled payment for THIS reservation) and issue an offline Ed25519 rental token (licence-free scooters need no KYC; a `needs_licence` vehicle is refused here and sent to `rent_motorcycle`) |
| `POST /kiosk/rent_motorcycle` | `rent_motorcycle(reservation_id)` | The combustion motorcycle; KYC-gated on `age_over_18` AND `licence_a` (category-A licence) before it issues a token |
| `POST /kiosk/request_kyc` | `request_kyc` | Hand back the broker link the human completes; the `kyc_verification` event then carries the signed attestation |

Plus the two reserved endpoints every origin serves: `POST /kiosk/pay` —
settle the AP2 mandate chain (intent → cart → payment) through Stripe — and
`GET /kiosk/schema`, the public catalog of everything above (no token, no
toll), with `GET /kiosk/openapi.json` rendering the same registry as OpenAPI.

Advertised capabilities are `[schema, queries, actions, pay, events]` — the MODULES
this origin serves, never the registered verb names. That is a MODELLING rule,
not a security one (spec §4.2): `GET /kiosk/schema` is public, so there is
nothing to withhold — this document is a POINTER and the catalog is the
CONTRACT, and a second copy of the verb list would be a second source of truth
for it. Registration is priced
with one Equihash proof-of-work at n=96 k=5, lighter than the
bundled solver's own default (see `before-after.md`) — the "I'm not a
fly-by bot" cost. Renting the motorcycle
additionally demands a signed KYC attestation carrying the required boolean
attributes; the operator records only the booleans, never the underlying
documents.

**What this KYC proves, and what it deliberately does not (honest scope).** The
attestation proves the assistant is *eligible* — that a valid category-A licence
and 18+ age *exist* behind it, anonymized to two booleans. It does **not**
identify the rider or make anyone *accountable* for this rental: an anonymized
eligibility claim is transferable (a friend who holds a licence could vouch), and
the demo settles a nameless hold, not a deposit. Real high-value rental layers
identity, a signed contract, insurance, and a real deposit on top — none of which
this demo models. **Anonymized minimal KYC is an eligibility gate, not an
accountability mechanism.** Its clean home is a low-liability check where the
transaction simply closes — see the age-gated alcohol purchase in the getgrocery
demo. (This scooter/motorcycle case is here to illustrate the attestation
*mechanism*, not to model real vehicle rental.)

## The human channel

Renting is the assistant's story, but the account behind it belongs to a person,
and the surfaces where that person approves an assistant — the device verify
page, the link-code mint, the unlink — are authenticated by **real Devise**
(`kiosk-user-idp-devise` reading the Warden session), not by a stub. The seeded
riders `ada@example.com` and `ben@example.com` sign in at `/users/sign_in`; an
assistant that redeems a code one of them mints is bound to THAT account and
reads only its reservations. Assistants never touch this channel — kiosk-pop key
possession is their only credential.

## Running it

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3004>.

On your own machine you need:

- **Ruby 3.2.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.
- **stripe-mock** on PATH for the tests — `brew install stripe-mock`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_skooti_development, then seeds the fleet
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does; the KYC tests stand in for the broker with
`Kiosk::TestHelpers::Kyc`. CI's red-team battery (`script/redteam_suite.rb`)
runs against the live broker in `kiosk-demo-prove`.

Two more entry points are hardware-side: `bin/make-qr` renders the scooter QR
codes, and `bin/ble-unlock` writes a rental token to a flashed ESP32-C3 lock
over BLE from a laptop. Both are documented in `firmware/README.md`;
`bin/ble-unlock` is UNVERIFIED until it is run against a real board.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and rent me a scooter for an hour and pay for it.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`ada@example.com` / `skooti-demo-password` and approve it there.

See `before-after.md` for why AI assistants stall at scooter rental today and
what this demo proves.
