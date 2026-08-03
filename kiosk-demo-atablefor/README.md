# kiosk-demo-atablefor

Restaurant table-booking demo operator for Kiosk — the flagship of the demo
redesign and the reference for the **viewable board** sharing pattern.

`atablefor` is a fake-but-realistic restaurant (**Tasca do Tejo**, Alfama,
Lisbon) that takes table reservations over the Kiosk wire — the "book a table
for two, tomorrow at 8" story, completed by an AI assistant with **no human
present, no web sign-in, and no payment** (a reservation takes no money; any €
figure shown is a no-show hold settled at the restaurant, never on the wire).

The home page is **protocol-primary**: it tells a visitor (and an assistant
scanning it) that this is a Kiosk endpoint to point an assistant at — not a
human web-booking form. A human diner *does* have a **real account** at the
restaurant (Devise sign-in, promoted as **Staff login**) and can **link their AI
assistant** to it: the diner signs in, mints a link code, the assistant redeems
it, and the assistant's bookings then tie to the diner's account
(`demo:binding`).

Every confirmed reservation shows on a **public, read-only reservations board**
(`/reservations`, and inline on the home page) as *party size · table · time ·
diner name* — so after an assistant books and links, a viewer SEES the booking
land under the diner's name.

## Wire surface

- `query availability(date, party_size)` — open table time-slots that seat the
  party, with the restaurant name, table label, and any EUR no-show hold
- `query my_bookings` — this principal's bookings (owner-scoped), with table + restaurant
- `run book_table(date, time, party_size)` — confirm a reservation on an open slot
- `run cancel_booking(booking_id)` — cancel one of your own bookings (owner-scoped)
- `schema` — self-discovery

There is **no `pay`**: the advertised capabilities are `[schema, query, run]`.

## Running it

Postgres required. From this directory:

```
bin/rails demo:setup       # create + load schema + seed Tasca do Tejo, its named tables, and diners
bin/rails demo:book        # the headline: register → availability → book_table(party 2) → my_bookings
bin/rails demo:binding     # a diner signs in (Devise), links their assistant, and its booking ties to the diner
bin/rails demo:isolation   # cross-tenant denial (an operator's booking is only yours)
bin/rails demo:redteam     # adversarial regression battery
bin/rails demo:schema      # self-discovery; asserts `pay` is absent
bin/rails demo:pow         # Equihash PoW gate (prices reservation-scalping at the door)
bin/rails demo:reputation  # anti-scalping: PoW cost drops as a real booking history accrues
bin/rails demo:walkthrough # curl-driven tour of the wire surface
```

Named tables (*Window 6, Bar 1, Terrace 2, Garden 4*) are seated across three
seatings (19:00 · 20:00 · 21:00) for the next few evenings; "tomorrow at 8"
lands on a 2-top at 20:00.

See `before-after.md` for why AI assistants stall at restaurant booking today and
what this demo proves.
