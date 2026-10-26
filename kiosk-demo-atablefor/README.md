# kiosk-demo-atablefor

Restaurant table-booking demo operator for Kiosk — the flagship of the demo
redesign and the reference for the **viewable board** sharing pattern.

`atablefor` is a fake-but-realistic restaurant **aggregator** — a handful of
coined Lisbon restaurants across a few neighbourhoods (Alfama, Graça, Bairro
Alto, Belém, Príncipe Real), each with a few finite named tables — that takes
table reservations over the Kiosk HTTP API. The "book a table for two tonight at 8"
story, completed by an AI assistant with **no human present, no web sign-in, and
no payment** (a reservation takes no money).

Seatings are **rolling-current**: `availability` computes the upcoming evening
seatings relative to *now* on **each restaurant's own clock** (`restaurants.timezone`;
past ones filtered), for today and the next 13 days, so it is never stale — yet the tables are **finite** and a fully-booked
seating is honestly **sold out** (availability legitimately empty for it).

The home page is **protocol-primary**: it tells a visitor (and an assistant
scanning it) that this is a Kiosk endpoint to point an assistant at — not a
human web-booking form. A human diner *does* have a **real account** at the
restaurant (Devise sign-in, promoted as **Diner sign-in**) and can **link their AI
assistant** to it: the diner signs in, gets a link code, the assistant uses
it, and the assistant's bookings then tie to the diner's account.

Every confirmed reservation shows on a **public, read-only reservations board**
(`/reservations`, and inline on the home page) as *party size · restaurant
(neighbourhood) · table · time · diner name*, spanning all the restaurants — so
after an assistant books and links, a viewer SEES the booking land under the
diner's name.

## HTTP API

One endpoint per verb: a query is a `GET` whose arguments are the query string,
an action is a `POST` whose arguments are the JSON body, and a success body IS
the result (no envelope).

- `GET /kiosk/availability?party_size=2[&neighborhood=&time=&date=]` — open tables
  **across all restaurants** for the upcoming seatings that seat the party (`date`
  takes today or one of the next 13 days; with no `date`, today and tomorrow); each
  row carries `restaurant_table_id`, `seating_at` (ISO 8601 with the restaurant's
  offset) and `seating_label` (`Sun 18 Oct, 20:00 (Europe/Lisbon)`, the line to
  read to a human). When the caller's `Kiosk-Timezone` is on another clock than
  the restaurant, a row also carries `timezone_note`: one sentence that names
  the restaurant's zone and how many hours it is from the caller's
- `GET /kiosk/my_bookings` — the signed-in customer's bookings, with table + restaurant
- `POST /kiosk/book_table {restaurant_table_id, seating_at, party_size}` — book the
  table and seating of an availability row; a table already taken for that
  seating, or a seating that has passed, is refused
- `POST /kiosk/cancel_booking {booking_id}` — cancel one of your own bookings
- `GET /kiosk/schema` — self-discovery

`book_table` answers with the same row `my_bookings` lists, and `seating_at` is
the same string in `availability`, `book_table` and `my_bookings`.

There is **no `pay`**: the advertised capabilities are `[schema, queries, actions]`.

The verbs above are ordinary Rails controllers, one per resource:
`app/controllers/kiosk/tables_controller.rb` serves `availability` and
`app/controllers/kiosk/bookings_controller.rb` serves `my_bookings`,
`book_table` and `cancel_booking`. Both `include Kiosk::Handler`, and each
declaration says which kind of verb it is with `kind :query` / `kind :action`.
Each is declared with the class-level descriptor macros. A refusal is a raised
`Kiosk::Server::Errors` error or a failed model validation, which the protocol turns
into the RFC 9457 problem document an assistant branches on. Every verb's
`input_schema` is validated on every call, so an undeclared argument is a typed
`400` naming it. A handler is reached only through the protocol.
`config/initializers/kiosk.rb` is configuration only.

## Running it

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3002>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant solves an Equihash toll with the bundled `solve.py`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_atablefor_development, then seeds restaurants, tables and diners
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does; each one registers an assistant and solves its toll.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and book me a table for two tonight at eight somewhere in Alfama.

It discovers the protocol, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`bea@example.com` / `atablefor-demo-password` and approve it there.

Each restaurant offers its named tables (varying capacities) for three evening seatings (19:00 · 20:00 · 21:00), computed
rollingly on the restaurant's own clock; "tonight at 8" lands on an open 2-top at 20:00.

See `before-after.md` for why AI assistants stall at restaurant booking today and
what this demo proves.
