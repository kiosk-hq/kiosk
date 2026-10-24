# Changelog — kiosk-demo-atablefor

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

- 2026-10-24: A migration adds `kiosk.agents.bound_at`; the manage-assistants page shows when each assistant was linked.
- 2026-10-22: `availability` and `book_table` take a seating today or on the next 13 days; a search with no date shows today and tomorrow. The page states the toll every demo asks.
- 2026-10-22: A migration adds `kiosk.agents.calls_since_proof`; an assistant pays a proof on every 10th call with no recent spend.
- 2026-10-21: A migration drops `kiosk.auth_challenges`; `agents.txt` names `Authorization: oauth2`.
- 2026-10-20: `availability` rows carry `timezone_note` when the caller's declared `Kiosk-Timezone` is on another clock than the restaurant.

- 2026-10-18: atablefor runs its jobs on Solid Queue inside Puma, so a booking seated after a restart still counts as a visit.

- 2026-10-17: atablefor tolls registration only, at the Equihash default: the reputation search toll and the discovery `pow_notice` are removed.

- `availability` rows no longer carry `deposit_eur`: a reservation takes no money. `book_table`'s `time` is one of the seating times, and `party_size` is at most 20.

- Every environment charges the reputation-priced Equihash toll at n=168 k=7; `KIOSK_POW_MODE` and its other modes are gone.

- The `check:` rake tasks and `bin/demo` are replaced by `bin/rails test`.

- The PoW mode is chosen by `KIOSK_POW_MODE` alone; the three per-mode alias flags are gone.

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
