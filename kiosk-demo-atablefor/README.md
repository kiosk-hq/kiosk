# kiosk-demo-atablefor

Restaurant table-booking demo operator for Kiosk — the flagship of the demo
redesign and the reference for the **viewable board** sharing pattern.

`atablefor` is a fake-but-realistic restaurant **aggregator** — a handful of
coined Lisbon restaurants across a few neighbourhoods (Alfama, Graça, Bairro
Alto, Belém, Príncipe Real), each with a few finite named tables — that takes
table reservations over the Kiosk wire. The "book a table for two tonight at 8"
story, completed by an AI assistant with **no human present, no web sign-in, and
no payment** (a reservation takes no money; any € figure shown is a no-show hold
settled at the restaurant, never on the wire).

Seatings are **rolling-current**: `availability` computes the upcoming evening
seatings relative to *now* on **each restaurant's own clock** (`restaurants.timezone`;
past ones filtered, rolling to tomorrow), so it is never stale — yet the tables are **finite** and a fully-booked
seating is honestly **sold out** (availability legitimately empty for it).

The home page is **protocol-primary**: it tells a visitor (and an assistant
scanning it) that this is a Kiosk endpoint to point an assistant at — not a
human web-booking form. A human diner *does* have a **real account** at the
restaurant (Devise sign-in, promoted as **Staff login**) and can **link their AI
assistant** to it: the diner signs in, mints a link code, the assistant redeems
it, and the assistant's bookings then tie to the diner's account.

Every confirmed reservation shows on a **public, read-only reservations board**
(`/reservations`, and inline on the home page) as *party size · restaurant
(neighbourhood) · table · time · diner name*, spanning all the restaurants — so
after an assistant books and links, a viewer SEES the booking land under the
diner's name.

## Wire surface

One endpoint per verb: a query is a `GET` whose arguments are the query string,
an action is a `POST` whose arguments are the JSON body, and a success body IS
the result (no envelope).

- `GET /kiosk/availability?party_size=2[&neighborhood=&time=&date=]` — open tables
  **across all restaurants** for the upcoming seatings that seat the party;
  answers a bare array whose rows carry `restaurant_id`, `restaurant_table_id`,
  `seating_date`, `seating_time`, `seating_label` (the seating with the zone it
  is written in — `20:00 (Europe/Lisbon)`, because a bare `20:00` is a wall
  clock with no clock named), `seating_at`, and any EUR no-show hold
- `GET /kiosk/my_bookings` — this principal's bookings (owner-scoped), with table + restaurant
- `POST /kiosk/book_table {restaurant_id, restaurant_table_id, date, time, party_size}` —
  reserve a specific table at a chosen restaurant for a chosen seating; a table
  already taken for that seating (or a seating that has passed) is rejected cleanly
- `POST /kiosk/cancel_booking {booking_id}` — cancel one of your own bookings (owner-scoped)
- `GET /kiosk/schema` — self-discovery

`seating_at` is one field on one clock across every verb that publishes it:
`availability`, the `book_table` confirmation and `my_bookings` all spell it
with the restaurant's own offset, so a booking read back after the fact is the
same string it was confirmed with. Two spellings of one instant under schema
text that describes the field identically is a difference a reader cannot
resolve, so there is only ever one.

There is **no `pay`**: the advertised capabilities are `[schema, queries, actions]`.

The verbs above are ordinary Rails controllers, not initializer blocks:
`app/controllers/kiosk/dining_room_controller.rb` holds the two queries and
`app/controllers/kiosk/bookings_controller.rb` the two actions — both
`include Kiosk::Handler`, and each declaration says which verb reaches it with
`kind :query` / `kind :action`, so the two-file split is this demo's choice
rather than the framework's. Each is declared with the class-level descriptor
macros; refusals are plain `render json:, status:` naming a wire
error `code`, which the wire carries into the RFC 9457 problem document an
assistant branches on. Every verb's `input_schema` is validated on every call,
so an undeclared argument is a typed `400` naming it. Neither controller is
routable — a handler is reached only through the wire.
`config/initializers/kiosk.rb` is configuration only.

## Running it

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3002>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — every assistant pays an Equihash toll at n=168 k=7
  (~10 s and ~1.3 GiB per proof), solved by the bundled `solve.py`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_atablefor_development, then seeds restaurants, tables and diners
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does; each one registers an assistant and pays its toll, so the run
takes a few minutes.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and book me a table for two tonight at eight somewhere in Alfama.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`bea@example.com` / `atablefor-demo-password` and approve it there.

Each restaurant offers its named tables (varying capacities, some with an EUR
no-show hold) for three evening seatings (19:00 · 20:00 · 21:00), computed
rollingly on the restaurant's own clock; "tonight at 8" lands on an open 2-top at 20:00.

See `before-after.md` for why AI assistants stall at restaurant booking today and
what this demo proves.
