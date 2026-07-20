# kiosk-demo-atablefor

Restaurant table-booking demo provider for Kiosk.

`atablefor` is a fake-but-realistic restaurant (Mamma Pizza) that takes table
reservations over the Kiosk wire — the "book a table for two, tomorrow at 8"
story, completed by an agent with no human present and no payment (a
reservation takes no money).

## Wire surface

- `query availability(date, party_size)` — open table time-slots that seat the party
- `query my_bookings` — this principal's bookings (owner-scoped)
- `run book_table(date, time, party_size)` — confirm a reservation on an open slot
- `run cancel_booking(booking_id)` — cancel one of your own bookings (owner-scoped)
- `schema` — self-discovery

There is **no `pay`**: the advertised capabilities are `[schema, query, run]`.

## Running it

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed Mamma Pizza and its tables
bin/rails demo:book        # the headline: register → availability → book_table(party 2) → my_bookings
bin/rails demo:isolation   # cross-tenant denial (an operator's booking is only yours)
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery; asserts `pay` is absent
bin/rails demo:pow         # Equihash PoW gate (prices reservation-scalping at the door)
bin/rails demo:reputation  # anti-scalping: PoW cost drops as a real booking history accrues
bin/rails demo:walkthrough # curl-driven tour of the wire surface
```

See `before-after.md` for why agents stall at restaurant booking today and what
this demo proves.
