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

- `query scooters_available` — browse the fleet (scooters + motorcycles);
  `needs_licence` flags the KYC-gated combustion vehicles
- `query my_reservations` — this principal's reservations (owner-scoped)
- `run reserve(scooter_code)` — reserve a vehicle by its code (TTL hold)
- `run payment_setup` — check whether the principal has a saved payment method
- `run start_rental(reservation_id)` — verify two gates (ownership and a settled
  payment for THIS reservation) and issue an offline Ed25519 rental token
  (licence-free scooters need no KYC)
- `run rent_motorcycle(reservation_id)` — the combustion motorcycle; KYC-gated
  on `age_over_18` AND `licence_a` (category-A licence) before it issues a token
- `pay` — settle the AP2 mandate chain (intent → cart → payment) via the stub PSP
- `schema` — self-discovery

Advertised capabilities are `[schema, query, run, pay]`. Registration is priced
with one Equihash proof-of-work (lighter than the default; see
`before-after.md`) — the "I'm not a fly-by bot" cost. Renting the motorcycle
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

## Running it

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed the fleet
bin/rails demo:rideflow    # the headline: register → KYC → scooters_available → reserve → pay → start_rental → offline unlock (plus the negative gates)
bin/rails demo:kyc         # the KYC-gated motorcycle path (age_over_18 + licence_a)
bin/rails demo:isolation   # cross-tenant + cross-scooter denial
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery over the schema verb
bin/rails demo:kat         # known-answer test for the offline rental-token issuer (DB-free)
```

`bin/rails demo` runs `demo:setup` then `demo:rideflow`.

See `before-after.md` for why AI assistants stall at scooter rental today and
what this demo proves.
