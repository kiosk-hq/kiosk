# Before and after — restaurant table booking

**For an operator weighing adoption:** what an AI assistant cannot do at a
reservation platform today, and what the same errand looks like once this
demo's wire is installed. The code is in this directory; this is the argument.

atablefor is a fake-but-realistic Lisbon restaurant aggregator. Nothing here
says any real platform works this way.

## Today

A personal AI assistant can find a restaurant. It cannot hold a table. Booking
sits behind an account, an anti-bot screen and a confirmation the human takes
in the operator's own app. The in-chat commerce connectors that exist today
stop at discovery: they surface options and deep-link the human out.

The ceiling is economic, not technical. A booking taken silently through an API
leaves no authenticated session — no placement, no upsell, no attribution. The
discovery funnel is the product.

## With atablefor

`rake check:book` runs the errand with no human, no web sign-in and no payment:
the assistant registers itself, reads `availability`, calls `book_table` for a
party of two and reads `my_bookings` back. A reservation
takes no money, so the card step and its PSD2 challenge — the wall that ends
the commerce demos in a handback — is not there at all. To watch an assistant
drive it rather than a script, see "Watch it work" in `README.md`.

## Pricing the scalper, not the diner

A table operator's fear is not fraud but reservation-scalping: scripts that
mass-claim prime-time two-tops to resell. Kiosk prices that at the door:

- `rake check:pow` gates the `availability` query behind an Equihash
  proof-of-work. A script probing inventory at scale pays a real per-query
  cost; one diner's assistant pays once. A toll, not a hardware wall.
- `rake check:reputation` makes that toll fall as a booking history accrues:
  two proofs unproven, one after a first confirmed booking, free with a real
  history. A scalper renting identities pays every time, and the factor is a
  `COUNT(*)` of confirmed bookings rather than a dial.

An assistant sees and cancels only its own bookings: `rake check:isolation` and
`rake check:redteam` assert that a cross-tenant read, a cross-owner cancel and
a forged `user_id` are each refused.

## What an operator adds

The Kiosk gems in `Gemfile`, then one command:

<!-- derived: generator | from: kiosk-server/lib/generators/kiosk/install/install_generator.rb | why: the one command an adopter types, held to the namespace that generator answers -->
```
rails g kiosk:install
```

It writes `config/initializers/kiosk.rb` and the `kiosk.*` migrations. What is
left is read in the directory rather than quoted here:
`config/routes/kiosk.rb`, the engine mounted in one line and then one route per
verb — GET for a query, POST for an action — and
`app/controllers/kiosk/{dining_room,bookings}_controller.rb`, the verbs as
ordinary Rails controllers. The toll and the reputation policy are the
initializer's.

No new human-facing login, no ceded customer relationship, no change to the
site humans use.
