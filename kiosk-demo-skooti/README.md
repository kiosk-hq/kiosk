# kiosk-demo-skooti

Scooter rental demo operator for Kiosk.

`skooti` is a fake-but-realistic micromobility operator that rents scooters —
and a KYC-gated combustion motorcycle — over the Kiosk wire. An AI assistant
self-registers, reserves a vehicle, pays, and unlocks it, with no human at the
keyboard. Payment settles through a **stub PSP** (`StubPsp`), so the demo runs
end-to-end with no real card processor. The physical last mile is a
software-simulated lock that verifies an offline Ed25519 rental token — no
server round-trip.

## Wire surface

One endpoint per verb: a read is a `GET` at its own name with arguments in the
query string, a write is a `POST` at its own name with a JSON body. Success is
the handler's payload with no envelope around it (a query always answers an
array); a refusal is an RFC 9457 problem document whose `code` is a flat
member. The 0.3 `POST /kiosk/query` and `POST /kiosk/run` are the ordinary 404
an authenticated caller gets; without a bearer they are `401 unauthenticated`,
because the wire resolves the caller before it looks the verb up.

| Endpoint | Verb | What it does |
|---|---|---|
| `GET /kiosk/scooters_available` | `scooters_available` | Browse the fleet (scooters + motorcycles); `needs_licence` flags the KYC-gated combustion vehicles |
| `GET /kiosk/my_reservations` | `my_reservations` | This principal's reservations (owner-scoped) |
| `GET /kiosk/kyc_status` | `kyc_status` | Which anonymized attributes this principal has already attested |
| `POST /kiosk/reserve` | `reserve(scooter_code)` | Reserve a vehicle by its code (inserts a `status='reserved'` row; the hold has no expiry/TTL — it stays until `start_rental` flips it to `active`) |
| `POST /kiosk/payment_setup` | `payment_setup` | Check whether the principal has a saved payment method |
| `POST /kiosk/start_rental` | `start_rental(reservation_id)` | Verify three gates (ownership, the vehicle being licence-free, and a settled payment for THIS reservation) and issue an offline Ed25519 rental token (licence-free scooters need no KYC; a `needs_licence` vehicle is refused here and sent to `rent_motorcycle`) |
| `POST /kiosk/rent_motorcycle` | `rent_motorcycle(reservation_id)` | The combustion motorcycle; KYC-gated on `age_over_18` AND `licence_a` (category-A licence) before it issues a token |
| `POST /kiosk/request_kyc` | `request_kyc` | Hand back the broker link the human completes to obtain the attestation |

Plus the two reserved endpoints every origin serves: `POST /kiosk/pay` —
settle the AP2 mandate chain (intent → cart → payment) via the stub PSP — and
`GET /kiosk/schema`, the public catalog of everything above (no token, no
toll), with `GET /kiosk/openapi.json` rendering the same registry as OpenAPI.

Advertised capabilities are `[schema, queries, actions, pay]` — the MODULES
this origin serves, never the registered verb names. That is a MODELLING rule,
not a security one (spec §4.2): `GET /kiosk/schema` is public, so there is
nothing to withhold — this document is a POINTER and the catalog is the
CONTRACT, and a second copy of the verb list would be a second source of truth
for it. Registration is priced
with one Equihash proof-of-work whose cost the operator picks with the
`KIOSK_POW_DIFFICULTY` knob; skooti ships the `low` setting, lighter than the
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

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed the fleet
bin/rails demo:rideflow    # the headline: register → scooters_available → reserve → pay → start_rental → offline unlock (no KYC leg — see demo:kyc; plus the negative gates)
bin/rails demo:kyc         # the KYC-gated motorcycle path (age_over_18 + licence_a)
bin/rails demo:isolation   # cross-tenant + cross-scooter denial
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery over the schema verb
bin/rails demo:kat         # known-answer test for the offline rental-token issuer (DB-free)
```

`bin/rails demo` runs `demo:setup` then `demo:rideflow`.

Two more entry points are hardware-side rather than rake tasks: `bin/make-qr`
renders the scooter QR codes, and `bin/ble-unlock` writes a rental token to a
flashed ESP32-C3 lock over BLE from a laptop — the no-iPhone way to see the lock
click. Both are documented in `firmware/README.md`; `bin/ble-unlock` is
UNVERIFIED until it is run against a real board.

<!-- CI-TASKS:BEGIN — generated by bin/check-ci-tasks --write; do not edit by hand -->
### Which of these run in CI

`.github/workflows/ci.yml` runs the tasks marked **yes** on every push and pull
request; the rest are local-only, for the reason given. This table is generated
from the workflow by `bin/check-ci-tasks`, which fails the build when the
workflow, this table and `lib/tasks/demo.rake` disagree — so a task that carries
assertions cannot go ungated and unexplained.

| Task | Runs in CI | Why not |
|---|---|---|
| `demo:kat` | yes |  |
| `demo:setup` | yes — the job's own setup step |  |
| `demo:rideflow` | yes |  |
| `demo:isolation` | yes |  |
| `demo:redteam` | yes |  |
| `demo:schema` | yes |  |
| `demo:kyc` | yes |  |
<!-- CI-TASKS:END -->

See `before-after.md` for why AI assistants stall at scooter rental today and
what this demo proves.
