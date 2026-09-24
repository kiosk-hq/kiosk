# Changelog — kiosk-demo-atablefor

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

- `book_table` takes one spelling of a date. Its `date` argument is
  `YYYY-MM-DD` and nothing else; every other spelling is a typed 400 naming
  what is accepted, so the handler is no longer looser than the
  `format: "date"` the verb publishes.

- Reshape atablefor from a single date-offset-seeded restaurant into a finite
  restaurant aggregator (~5 coined Lisbon restaurants with named tables) whose
  seatings roll to the current upcoming evenings in Europe/Lisbon (lib/seatings),
  so availability is never stale while tables remain finite and can sell out;
  `availability` aggregates open tables across restaurants with neighbourhood/
  time/date filters, and `book_table` reserves a specific (restaurant, table,
  seating) with clean sold-out contention. No payment added (deposit stays
  display-only). Fixes the staleness the old date-offset seeding produced.
