# kiosk-demo-hoteling

Hotel booking demo operator for Kiosk.

`hoteling` is a fake-but-realistic hotel operator that takes room bookings
over the Kiosk wire — the "book me a room for those dates" story, completed
by an AI assistant with no human present, and gated on payment (a booking is
only confirmed once it is paid for). Payment is kiosk-pay-stripe in Stripe test
mode — the tasks and CI charge a local stripe-mock — and a booking the property
declines is refunded to the card that paid.

## Wire surface

One endpoint per verb: a query is `GET /kiosk/<query-name>` with
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
  (served by kiosk-server)
- `POST /kiosk/confirm_booking` — confirm a reserved booking; requires a
  settled payment whose cart mandate references this booking
- `POST /kiosk/pay` — settle the AP2 mandate chain (intent → cart → payment)
  through Stripe
- `GET /kiosk/schema` — self-discovery
- `GET /kiosk/openapi.json` — the DERIVED OpenAPI description of the above, for
  tooling; the catalog at `/kiosk/schema` stays canonical

Advertised capabilities are `[schema, queries, actions, pay, events]` — the MODULES
this origin serves, never the registered verb names. That is a MODELLING rule,
not a security one (spec §4.2): `GET /kiosk/schema` is public, so there is
nothing to withhold — this document is a POINTER and the catalog is the
CONTRACT, and a second copy of the verb list would be a second source of truth
for it. **Registration is
always gated by Equihash proof-of-work** (`registration_pow_count = 1`) — every
new agent key pays one solve to register. Separately, a browse toll prices
QUERIES after the first few free ones, and each `reserve_room` hold costs one
proof — a metered toll, not a wall: an AI assistant pays a few seconds of compute
to look deeper, a bulk scraper pays linearly and forever.

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

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3003>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.
- **stripe-mock** on PATH for the tests — `brew install stripe-mock`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_hoteling_development, then seeds the hotels
bin/dev                # serves the origin on http://localhost:3000
bundle exec rspec      # the tests; CI runs exactly this
```

`bin/setup` does the first two. The stories in `spec/stories/` drive the origin over
HTTP the way an assistant does. `spec/conformance/` is written with the matchers
`kiosk-test-support` ships, and is the file to copy when you are adding a Kiosk
wire to an app of your own; `kiosk-demo-getgrocery` is the same surface in
Minitest.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and book me a room for two nights next month and pay for it.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`ada@example.com` / `hoteling-demo-password` and approve it there.

See `before-after.md` for why AI assistants stall at hotel booking today and
what this demo proves.
