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
- `run start_rental(reservation_id)` — verify three gates (ownership, KYC,
  settled payment for THIS reservation) and issue an offline Ed25519 rental token
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
