# Before and after — hotel booking

**What this file is for.** An operator weighing adoption: what an AI assistant
cannot do at a booking platform today, and what the same errand looks like once
this demo's wire is installed. The code is in this directory; this is the
argument, not a listing.

hoteling is a fake-but-realistic hotel operator built to show the mechanism.
Nothing here implies any real platform works this way, and whether operators
adopt it is an open question.

## Today

Every current personal AI assistant stalls at the same wall: the connector
stops at discovery. The Booking.com connector in Claude exposes two tools — a
property search and a question-answering tool — and its session schema carries
a deep-link field. There is no reserve, no checkout and no payment tool. The
assistant shows options and hands the human back to Booking.com to register,
authenticate and pay.

The root cause is economic, not technical. Display advertising, metasearch
fees, loyalty points and first-party data capture all need the human inside the
operator's own funnel; a silent reservation through a structured API erases
that session. The discovery step is the product. Anti-bot friction compounds
it: behavioural fingerprinting flags assistant traffic, the card lives outside
the assistant's context, and PSD2 SCA needs a challenge only the human can
answer.

## With hoteling

`rake check:book` runs the errand with no human present: the assistant
registers itself under the toll, reads `availability`, calls `reserve_room`,
signs the three AP2 mandates and pays, and the booking is confirmed only once
payment settles. Settlement goes through a stub PSP, so the whole flow runs
with no real card processor.

Two things the incumbent flow cannot do follow from that. Payment is part of
the wire rather than a handback, so the reservation completes in one exchange.
And the booking is the assistant's own: `rake check:isolation` and
`rake check:redteam` assert a cross-tenant read and a forged `user_id` are
refused, while `rake check:spending_cap` holds a per-assistant limit the
operator sets.

To watch an assistant drive it rather than a script, see "Watch it work" in
`README.md`.

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
`app/controllers/kiosk/{hotels,reservations}_controller.rb`, the verbs as
ordinary Rails controllers. The toll, the PSP adapter and the spending cap are
the initializer's.

No new human-facing login, no ceded customer relationship, no change to the
site humans use.
