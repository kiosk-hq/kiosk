# kiosk-demo-skooti

Scooter rental demo operator for Kiosk.

`skooti` is a fake-but-realistic micromobility operator that rents scooters —
and a KYC-gated combustion motorcycle — over the Kiosk wire. An AI assistant
self-registers, reserves a vehicle and pays for it with no account of its
human's and no sign-in anywhere, and comes away with a short-lived signed
token that opens that one vehicle. The last step is the human's, because it is
physical: they present the token at the scooter — a tap on its NFC tag or a
scan of its QR opens the App Clip, which writes the token to the lock over
Bluetooth. Payment settles through a **stub PSP** (`StubPsp`), so the demo
runs end-to-end with no real card processor. The lock verifies the offline
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

<!-- PREREQS:BEGIN — generated by bin/check-demo-prereqs --write; do not edit by hand -->
### Prerequisites

Generated by `bin/check-demo-prereqs` from this demo's own files — the build fails when
this list and the code that needs it disagree.

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3004>.
To run one of this demo's own tasks instead of the server:

```
docker compose run --rm app bin/rails <task>
```

The list below is the HOST path — what running `bin/rails demo:*` on your own machine
needs. It is not shorter under containers; it is unnecessary.

- **Ruby 3.2.0 or newer**, then `bundle install` — the floor every kiosk gem declares in its `required_ruby_version`.
- **Postgres**, reachable — `pg_isready` returns OK — with `psql` on PATH: the demo tasks shell out to it directly, not only through ActiveRecord.
- **A Postgres login permitted to `CREATE ROLE`.** `demo:setup` creates the `app_role` group role and grants it to the current user. Managed Postgres and shared development servers usually refuse this; a local superuser has it.
- **python3 with numpy** — check with `python3 -c "import numpy"`. Registering an assistant pays an Equihash toll, and every task that registers one solves it with the bundled `solve.py`; without numpy the solver exits `this solver requires numpy` and the task fails at its first step.

> **`demo:setup` is destructive, and every task that depends on it inherits that.**
> It runs `db:drop db:create db:schema:load db:seed` unconditionally — no environment
> check, no confirmation prompt — so running it **DROPS and recreates**
> `kiosk_skooti_development`. Nothing you left in that database survives.
> The SERVER is `localhost`, read from the same `config/database.yml` — unless
> `PGHOST` is exported, and then it is whatever host that names: the drop
> follows it, and takes that server's `kiosk_skooti_development` instead.
>
> Under `docker compose` the same drop still happens on every `up`, but it lands on the
> Postgres that compose brings up, on this project's own volume. It cannot reach a
> database on your machine: the compose file sets `PGHOST` to the container beside it
> rather than passing yours through.
>
> `bin/setup` is the shortcut, and it inherits the drop: `bundle install`, then `bin/rails demo:setup`, then `bin/rails log:clear tmp:clear`, then `bin/dev`.
>
> **AND SOME TASKS DROP A SECOND DATABASE, IN ANOTHER DEMO.** `demo:kyc`, `demo:redteam`
> boot the app in `kiosk-demo-prove` and set its database up the same destructive
> way, so running any of them also **DROPS and recreates** `kiosk_prove_development`. That is another
> demo's data, and nothing you left in it survives either.
<!-- PREREQS:END -->

From this directory:

```
bin/rails demo:setup       # DROPS and recreates the DB, then seeds the fleet
bin/rails demo:rideflow    # the headline: register → scooters_available → reserve → payment_setup → pay → start_rental → offline unlock (no KYC leg — see demo:kyc; plus the negative gates)
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
