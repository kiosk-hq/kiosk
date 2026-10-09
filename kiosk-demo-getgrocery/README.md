# kiosk-demo-getgrocery

Grocery delivery demo operator for Kiosk.

Single implicit store (getgrocery IS the store): `catalog` / `delivery_slots` /
`my_orders` queries, `create_order` / `reschedule_delivery` /
`request_kyc` actions (delivery slot + address are part of
`create_order`; `request_kyc` starts the 18+ anonymized check the alcohol gate
needs, and the `kyc_verification` event carries its signed outcome), real Stripe SetupIntent
card-on-file payments (stripe-mock when no key is set) behind a cashier check
(the cart must be EUR, mirror the order at catalog prices, and sum correctly),
and the claim-rebind half of the account-binding ceremony.

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3001>.

On your own machine you need:

- **Ruby 3.2.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.
- **stripe-mock** on PATH for the tests — `brew install stripe-mock`.

From this directory:

```
bin/rails db:reset         # DROPS and recreates kiosk_getgrocery_development, then seeds the catalog
bin/dev                    # serves the origin on http://localhost:3000
bin/rails test             # the tests; CI runs exactly this
bin/rails demo:reconcile   # settles orders stuck in `paying`; it reports, it does not assert
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does, and the age-check tests boot the KYC broker in
`kiosk-demo-prove`, which **drops and recreates `kiosk_prove_development`**.

`test/kiosk_conformance_test.rb` is the file to copy when you add a Kiosk wire
to an app of your own: the four properties the protocol makes normative of an
origin, asserted with the matchers `kiosk-test-support` ships.
`kiosk-demo-hoteling` is the same surface written in RSpec.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and order me milk, bread and coffee to my Dublin address in the first
> free evening slot, and pay with my card on file.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`hana@example.com` / `getgrocery-demo-password` and approve it there.

See `before-after.md` for why AI assistants stall at grocery delivery today and
what this demo proves.

## Delivery address is an upfront, deliberate input (ADDRESS-UPFRONT)

`delivery_slots` requires a `delivery_address` and validates it names a
**served Dublin postal district** (`app/models/dublin_zones.rb`): a district-less
address (`"…, Dublin"` with no `Dublin 2`/`D02`), an out-of-zone district, or a
non-Dublin city returns a clean **400 (`bad_request`)** whose message says what
is needed — so an assistant must obtain the address **before** it can even see
slots. `create_order` re-validates the same rule (consistency), and a mismatched
or out-of-zone address there is likewise a clean 400.

**Honest scope:** the operator validates **format and zone only**. It **cannot**
tell a fabricated-but-plausible in-zone address (`"1 Nonexistent Way, Dublin 2"`)
from a real one — there is no address-book lookup. This gate adds realism and
catches gross fakes; it is not proof the address exists. The real defense is the
**human** providing/confirming the address — the [Kiosk skill](https://kiosk.tech/skill.md)
instructs assistants to obtain such real-world details from the human and never
invent a placeholder.

## Delivery-slot times: whose clock, in each direction

A delivery happens **at the door**, so a window's wall clock belongs to the
**delivery address** — the served district it routed to, whose IANA zone is
declared in `DublinZones::ZONES`, one entry per district getgrocery delivers
to. Every one of them is in Dublin today, so a slot labelled `08:00–10:00
(Europe/Dublin)` means 08:00 in Dublin and each `delivery_slots` row's
`slot_at` carries the real offset (`+01:00` in summer IST, `+00:00` in winter
GMT). What matters is that it is a **map**: an operator does not answer from
one zone configured on the origin, because an operator may serve places in more
than one, and a depot opened elsewhere is one new row rather than an edit to a
verb. `Europe/Dublin` survives in `DeliverySlots` only as the default that
dates a published example, which addresses no district. The real IANA zone is
used — not a fixed offset — so DST is handled automatically
(`app/models/delivery_slots.rb`).

**A `date` YOU send is read in YOUR calendar.** Declare it in the
`Kiosk-Timezone` request header, as an IANA name, and `delivery_slots` reads a
day you name on your human's calendar rather than on the shop's. Declare
nothing and it is read at the delivery address. A calendar day is an
INTERVAL, so a day you are
still IN is never "in the past" even when the shop has already rolled over —
that is the 23:05 case the rule exists for — and the rows then come back on the
**shop's** calendar, which is how you learn that your tonight became its
tomorrow. A day you have entirely finished IS past, and is a `400` naming the
earliest day the shop can serve. `create_order`'s `delivery_date` is the other
case and its descriptor says so: it ECHOES a row, so it is read on the clock
that row was published on, or handing back the day you were offered would book
a different one.

**The row names its zone, and that is the point of it.** `slot_at` has
always been unambiguous, but nobody says an offset out loud: the field a human
is actually read out is `label`, and a bare `08:00–10:00` is a wall clock with
no clock named — a customer three hours away hears their own 08:00. So the row
carries `timezone` beside the label. It also carries `district` (the served
postal district, `D02`), which is a ROUTING key and not a time zone — one word
for both was unreadable three lines apart.

**Every verb that publishes this window publishes it the same way.**
`delivery_slots` offers a window, `create_order` books it,
`reschedule_delivery` moves it, and `my_orders` reads it back after the fact —
one field, one clock: the instant carries the DELIVERY zone's offset in every
one of the four, and a zone-bearing label from the one writer
(`DeliverySlots.label`) travels beside it in every one of the four (`label` on a
slot row, `slot_label` on an order and on the booking, `rescheduled_label` on
the move). An instant published with no clock named beside it is the same
instant in a second spelling, and `my_orders` is the verb §11.6 sends an
assistant to after a `pay` whose response was lost — which is exactly the row a
human hears read back.

`delivery_slots` returns only **still-bookable** windows: for **today** at the
delivery address, a slot whose start has already passed *there* is dropped
(querying at 11:00 Dublin hides
`08:00–10:00` and `10:00–12:00`; if every window has begun, today yields no slots
and the earliest is tomorrow — correct, not a bug). Future dates keep all slots.
`create_order`/`reschedule_delivery` re-validate the same rule (consistency): a
past-start slot for today is rejected with a clean **400 (`bad_request`)**, never
silently booked. `test/delivery_slots_test.rb` and `test/wire_arguments_test.rb`
pin the filter across DST and the caller's declared calendar.

## Age-restricted purchases (anonymized KYC)

One catalog item is age-restricted (a coined wine — no real brand). A cart
containing it can only be ordered (`create_order`) by an agent that has
completed an 18+ anonymized-KYC check via the shared **KYC broker** (kyc.demo.kiosk.tech)
(`POST /kiosk/request_kyc` → human approves a broker link → the broker signs
an anonymized `{age_over_18}` claim → the `kyc_verification` event carries it →
submit it to `POST /kiosk/agents/kyc`).
Non-restricted groceries need no KYC. `test/wire/age_check_test.rb` drives the
full two-server flow.

This age-gate is the **proper home** of anonymized KYC: a low-liability
*eligibility* check where the transaction closes. Anonymized KYC confirms a
fact (over 18) without identifying the person — so it does **not** confer
accountability, which is exactly why it is used here (eligibility) and NOT for
high-liability actions where the operator needs to know *who* is on the hook.
(getgrocery is a second broker operator; deploy allow-listing is a follow-up.)

Payments need `STRIPE_SECRET_KEY` (sk_test_…, real test-mode charge) or a
local stripe-mock; export `STRIPE_MOCK_URL=http://localhost:12111` to boot the
app secret-free, and the seeds then map the shopper's saved card to the mock's
card fixture. The tests always run against stripe-mock.

A test-mode key, where an operator has one, belongs in this demo's own
gitignored `mise.toml` (copy `mise.toml.example`) and is for hand-driven demo
runs only. It is never used by an automated test — `stripe-mock` is the double
there.

The human side of the claim ceremony (verify page, link mint, unlink)
authenticates through a **real Devise session** — `kiosk-user-idp-devise`
reading the Warden user, the same channel every other demo uses. The seeded
shopper `hana@example.com` signs in at `/users/sign_in`, and
`test/wire/claim_test.rb` drives that form rather than asserting a bearer. Assistants never touch this
channel — kiosk-pop key possession is their only credential.
