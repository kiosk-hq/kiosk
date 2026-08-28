# kiosk-demo-hoteling

Hotel booking demo operator for Kiosk.

`hoteling` is a fake-but-realistic hotel operator that takes room bookings
over the Kiosk wire — the "book me a room for those dates" story, completed
by an AI assistant with no human present, and gated on payment (a booking is
only confirmed once it is paid for). Payment settles through a **stub PSP**
(`StubPsp`), so the demo runs end-to-end with no real card processor.

## Wire surface

One endpoint per verb (protocol 0.4): a query is `GET /kiosk/<query-name>` with
its arguments in the query string, an action is `POST /kiosk/<action-name>` with
its arguments as the JSON body. A success body IS the result — a bare array of
rows from a query, the action's own object from an action — and an error is an
RFC 9457 problem document.

- `GET /kiosk/properties` — browse all available hotel properties
- `GET /kiosk/availability?property_id=&check_in=&check_out=` — check room
  availability for a stay
- `GET /kiosk/my_bookings` — this principal's bookings (owner-scoped)
- `GET /kiosk/search_hotels?...` — paginated search over the ~100-hotel
  catalogue; the only paginating verb here, and since RFC 8288 it answers the
  same bare array as the rest — a truncated page says so in a `Link: <…>;
  rel="next"` header, with `X-Total-Count` carrying the matching total
- `GET /kiosk/hotel_detail?property_id=` — ONE property in full, as a one-row
  array (a `property_id` no property has is 404 `not_found`)
- `POST /kiosk/reserve_room` — reserve a room for the principal (writes the
  booking plus the engine's reserve-then-pay row in `kiosk.reservations`,
  stamped with a 15-minute pay-by deadline — recorded for an operator to act
  on, not enforced by `confirm_booking`, which gates on ownership + payment)
- `POST /kiosk/payment_setup` — check whether the principal has a saved payment method
- `POST /kiosk/confirm_booking` — confirm a reserved booking; requires a
  settled payment whose cart mandate references this booking
- `POST /kiosk/pay` — settle the AP2 mandate chain (intent → cart → payment)
  via the stub PSP
- `GET /kiosk/schema` — self-discovery
- `GET /kiosk/openapi.json` — the DERIVED OpenAPI description of the above, for
  tooling; the catalog at `/kiosk/schema` stays canonical

Advertised capabilities are `[schema, queries, actions, pay]` — the MODULES
this origin serves, never the registered verb names. That is a MODELLING rule,
not a security one (spec §4.2): `GET /kiosk/schema` is public, so there is
nothing to withhold — this document is a POINTER and the catalog is the
CONTRACT, and a second copy of the verb list would be a second source of truth
for it. **Registration is
always gated by Equihash proof-of-work** (`registration_pow_count = 1`) — every
new agent key pays one solve to register. Separately, an **opt-in** browse toll
(off by default; enable with `KIOSK_POW_BROWSE_DEMO=1`) prices the browse-heavy
QUERY endpoints after the first few free availability queries — a metered toll, not
a wall: an AI assistant pays a few seconds of compute to look deeper, a bulk
scraper pays linearly and forever.

## The human channel

Hotel bookings are the assistant's story, but the account behind them belongs to
a person, and the surfaces where that person approves an assistant — the device
verify page, the link-code mint, the unlink — are authenticated by **real
Devise** (`kiosk-user-idp-devise` reading the Warden session), not by a stub.
The seeded guests `ada@example.com` and `ben@example.com` sign in at
`/users/sign_in`; an assistant that redeems a code one of them mints is bound to
THAT account and reads only its bookings. Assistants never touch this channel —
kiosk-pop key possession is their only credential.

## Running it

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed the properties and rooms
bin/rails demo:book        # the headline: register → availability → reserve_room → pay → confirm_booking (plus the payment-gate negative)
bin/rails demo:browse      # browse-heavy priced-pagination PoW demo — boots with the browse gate active (KIOSK_POW_BROWSE_DEMO=1); depth is priced, not banned
bin/rails demo:isolation   # cross-tenant denial (a booking is only yours)
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery over the schema verb
bin/rails demo:search      # pagination over the ~100-hotel catalogue: a truncated page carries `Link: …; rel="next"`, following it returns a DISJOINT page, a complete result carries no link, and hotel_detail resolves a summary row's id (404 for one nobody has)
```

**Every task above reseeds first.** Each of the tasks above except `demo:setup` itself declares `: :setup`, so
running any of them DROPS and recreates `kiosk_hoteling_development` before it
starts — nothing you left in the database survives a run, and that is what makes
each of them repeatable. `demo:book` was the one exception, and it was not
repeatable: the driver always picks the same property for the same three nights
and books it twice (happy path, then the payment-gate negative), so one pass took
that property's whole inventory — the negative's unpaid hold is never released,
by design — and a second `bin/rails demo:book` aborted with «availability
returned empty rows».

`bin/rails demo` runs `demo:setup` then `demo:book`.

<!-- CI-TASKS:BEGIN — generated by bin/check-ci-tasks --write; do not edit by hand -->
### Which of these run in CI

`.github/workflows/ci.yml` runs the tasks marked **yes** on every push and pull
request; the rest are local-only, for the reason given. This table is generated
from the workflow by `bin/check-ci-tasks`, which fails the build when the
workflow, this table and `lib/tasks/demo.rake` disagree — so a task that carries
assertions cannot go ungated and unexplained.

| Task | Runs in CI | Why not |
|---|---|---|
| `demo:setup` | yes — the job's own setup step |  |
| `demo:book` | yes |  |
| `demo:isolation` | yes |  |
| `demo:redteam` | yes |  |
| `demo:schema` | yes |  |
| `demo:search` | yes |  |
| `demo:browse` | yes |  |
<!-- CI-TASKS:END -->

See `before-after.md` for why AI assistants stall at hotel booking today and
what this demo proves.
