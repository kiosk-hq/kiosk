# kiosk-demo-hoteling

Hotel booking demo operator for Kiosk.

`hoteling` is a fake-but-realistic hotel operator that takes room bookings
over the Kiosk wire — the "book me a room for those dates" story, completed
by an AI assistant with no human present, and gated on payment (a booking is
only confirmed once it is paid for). Payment settles through a **stub PSP**
(`StubPsp`), so the demo runs end-to-end with no real card processor.

## Wire surface

- `query properties` — browse all available hotel properties
- `query availability(property, dates)` — check room availability for a stay
- `query my_bookings` — this principal's bookings (owner-scoped)
- `run reserve_room(...)` — reserve a room for the principal (creates a TTL hold)
- `run payment_setup` — check whether the principal has a saved payment method
- `run confirm_booking(booking_id)` — confirm a reserved booking; requires a
  settled payment whose cart mandate references this booking
- `pay` — settle the AP2 mandate chain (intent → cart → payment) via the stub PSP
- `schema` — self-discovery

Advertised capabilities are `[schema, query, run, pay]`. Only the `query` verb
(browsing) is priced with Equihash proof-of-work — a metered toll, not a wall:
an AI assistant pays a few seconds of compute to look deeper, a bulk scraper
pays linearly and forever.

## Running it

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed the properties and rooms
bin/rails demo:book        # the headline: register → availability → reserve_room → payment_setup → pay → confirm_booking (plus the payment-gate negative)
bin/rails demo:browse      # browse-only tour of the query surface
bin/rails demo:isolation   # cross-tenant denial (a booking is only yours)
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery over the schema verb
```

`bin/rails demo` runs `demo:setup` then `demo:book`.

See `before-after.md` for why AI assistants stall at hotel booking today and
what this demo proves.
