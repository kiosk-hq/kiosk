# kiosk-demo-hoteling

Hotel booking demo operator for Kiosk.

`hoteling` is a fake-but-realistic hotel operator that takes room bookings
over the Kiosk wire — the "book me a room for those dates" story, completed
by an AI assistant with no human present, and gated on payment (a booking is
only confirmed once it is paid for). Payment is kiosk-pay-stripe in Stripe test
mode — the tests and CI charge a local stripe-mock — and a booking the property
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
- `GET /kiosk/my_bookings` — the signed-in customer's bookings: each stay's
  status, its payment state and, once the hotel confirms it, its confirmation code
- `GET /kiosk/search_hotels?...` — paginated search over the ~100-hotel
  catalogue; the only paginating verb here, and since RFC 8288 it answers the
  same bare array as the rest — a truncated page says so in a `Link: <…>;
  rel="next"` header, with `X-Total-Count` carrying the matching total
- `GET /kiosk/hotel_detail?property_id=` — ONE property in full, as a one-row
  array (a `property_id` no property has is 404 `not_found`)
- `POST /kiosk/reserve_room` — hold a room type for a stay, for the signed-in
  customer, for 15 minutes; a hold left unpaid past that time is cancelled and
  its room is free for other guests
- `POST /kiosk/payment_setup` — check whether the customer has a saved payment method
  (served by kiosk-server)
- `POST /kiosk/pay` — pay the checkout with the closed AP2 checkout and payment mandates
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
new agent key pays one solve to register. After that, each access token (one
hour) pays one more solve by chance: 1 with no recent spend, 0 from 100 euros
paid here in the past week.

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

Payment goes to stripe-mock, a local copy of the Stripe API. stripe-mock alone
answers each charge with the status `requires_payment_method`, and the app reads
that as a declined payment. The relay in `kiosk-test-support` answers a
confirmed charge as `succeeded` and passes every other call to stripe-mock. The
tests use the same relay. Before `bin/setup`, start the relay in a second
terminal, from this directory:

```
export STRIPE_MOCK_URL=http://localhost:12111
ruby -I ../kiosk-test-support/lib -rkiosk/test_helpers/stripe_mock -e 'Kiosk::TestHelpers::StripeMock.start; sleep'
```

It starts stripe-mock and listens on port 12111. Then, in the terminal where you
run `bin/setup`, run `export STRIPE_MOCK_URL=http://localhost:12111`.
Without this variable the app sends each payment to the real Stripe API with a
placeholder key, and the payment fails. `docker compose up` does not start stripe-mock, so payment fails
there too.

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and book me a room for two nights next month and pay for it.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`ada@example.com` / `hoteling-demo-password` and approve it there.

See `before-after.md` for why AI assistants stall at hotel booking today and
what this demo proves.
