# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

## [0.5.20] — 2026-10-20

- 2026-10-20: Version 0.5.20, the tree cut that matches skill 0.5.20.

## [0.5.19] — 2026-10-20

- 2026-10-20: Version 0.5.19, the tree cut that matches skill 0.5.19.

## [0.5.18] — 2026-10-18

- 2026-10-18: Version 0.5.18, the tree cut that matches skill 0.5.18.

## [0.5.17] — 2026-10-18

- 2026-10-18: `RecentSpend` tolls every call of a caller whose token has no `iat` or `exp`, so a retry cannot fish for a free draw.
- 2026-10-18: `Policies::RateAndReputation` is removed; `Factors` keeps only `settled_purchases_count` and `settled_purchases_cents`.
- 2026-10-18: The README configures `RecentSpend`; `RateAndReputation` gets no factors behind the gate, and `on_bad_proof` records into a store the host owns.
- 2026-10-18: `Policies::Backoff` and `BackoffStore` are removed.
- 2026-10-18: `RecentSpend` draws once for each customer in each token lifetime, so a new access token in the same lifetime meets the same outcome.
- 2026-10-18: `RecentSpend` draws once per access token: the token's `jti` fixes the draw, so every call made with the token meets one outcome. `random:` is removed.

## [0.5.16] — 2026-10-18

- 2026-10-18: The README names kiosk-pow-argon2id for the Argon2id backend and points to kiosk-pow's guide to add a backend.

## [0.5.15] — 2026-10-18

- `Policies::RecentSpend.new(within:, cap:)` tolls a session with the chance `max(0, (cap - spend) / cap)`, `cap` in whole currency units; `trusted_at:` and `count:` are gone.

- The README says that `kiosk-pow-equihash` registers itself at Rails boot, and that the host registers any other backend.

## [0.5.14] — 2026-10-18

- 2026-10-18: Version 0.5.14, the tree cut that matches skill 0.5.14.

- 2026-10-18: `Policies::RecentSpend` asks one toll per session and lowers it by the customer's recent spend, to none at `trusted_at`.

- 2026-10-17: The docs say kiosk-pow-equihash registers itself in a Rails app; the ambiguity error no longer names the removed `registration_pow_params`.

- 2026-10-17: `Challenge.check` runs the signature, expiry and parameter checks alone, without the proof evaluation.
## [0.5.13] — 2026-10-11

- 2026-10-11: Version 0.5.13, the tree cut that matches skill 0.5.13; this gem's surface is unchanged.

## [0.5.12] — 2026-10-08

- 2026-10-08: Version 0.5.12, the tree cut that matches skill 0.5.12; this gem's surface is unchanged.

## [0.5.11] — 2026-10-08

- 2026-10-08: Version 0.5.11, the tree cut that matches skill 0.5.11; this gem's surface is unchanged.

## [0.5.10] — 2026-10-08

- 2026-10-08: Version 0.5.10, the tree cut that matches skill 0.5.10; this gem's surface is unchanged.

## [0.5.9] — 2026-10-08

- 2026-10-08: Version 0.5.9, the tree cut that matches skill 0.5.9; this gem's surface is unchanged.

## [0.5.8] — 2026-10-07

- 2026-10-07: Version 0.5.8, the tree cut that matches skill 0.5.8; this gem's surface is unchanged.

## [0.5.7] — 2026-10-07

- 2026-10-07: Version 0.5.7, the tree cut that matches skill 0.5.7; this gem's surface is unchanged.

## [0.5.6] — 2026-10-07

- 2026-10-07: Version 0.5.6, the tree cut that matches skill 0.5.6; this gem's surface is unchanged.

## [0.5.5] — 2026-10-07

- 2026-10-07: Version 0.5.5, the tree cut that matches skill 0.5.5; this gem's surface is unchanged.

## [0.5.4] — 2026-10-07

- 2026-10-07: Version 0.5.4, the tree cut that matches skill 0.5.4; this gem's surface is unchanged.

## [0.5.3] — 2026-10-06

- 2026-10-06: Version 0.5.3, the tree cut that matches skill 0.5.3; this gem's surface is unchanged.

## [0.5.2] — 2026-10-06

- 2026-10-06: Version 0.5.2, the tree cut that matches skill 0.5.2; this gem's surface is unchanged.

## [0.5.0] — 2026-09-26

### Changed

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- **Three packaged sentences priced a solve at «~9 s» with no solver, machine or parameters (K-1694).** The seconds are removed; the count-not-window argument is unchanged.
- **A signed challenge could be re-partitioned into another alg/params split under its own HMAC (K-1693).** `Challenge` now refuses a canonical-string delimiter in any field.
- **`Policy#challenge_for`'s `verb:` contract is stated as closed, and a wrong branch is no longer silent (K-1395).** The hook receives one of `:query`, `:run`, `:pay` and nothing else; a handler declared `kind :action` in kiosk-server arrives as `:run`. Branching on `:action` matched nothing and declined to toll every write with no error, log line or failing test. `kiosk-server` now refuses such a policy at configuration time. No behaviour change in this gem.

### Added

- Initial implementation.
- `Kiosk::Reputation::Backends` — algorithm registry: `register` / `fetch` / `known` / `reset!`.
- `Kiosk::Reputation::Backends.valid_params?(alg, params)` — the mint-time seam a gate asks before issuing a challenge (K-843). Duck-typed and opt-in: it answers `false` only when a registered backend says so itself, and `true` for an unregistered algorithm or one that expresses no opinion, so it can never invent a refusal.
- `Kiosk::Reputation::Challenge` — stateless, request-bound wire challenge: `issue` / `verify` with anti-DoS cheap-before-expensive ordering (HMAC sig + expiry before backend eval).
- `Kiosk::Reputation::Factors` — immutable Data class with all-nullable reputation fields; `.empty` constructor.
- `Kiosk::Reputation::Policy` — base class (never challenge); providers subclass or replace.
- `Kiosk::Reputation::Policies::RateAndReputation` — shipped EXAMPLE policy: escalates by Equihash proof COUNT (count-curve; no continuous difficulty dial) on high request rate, zero purchases, and bad-proof history; providers are expected to replace it.
- RSpec suite covering: challenge round-trip, tampered fields, fingerprint mismatch, wrong secret, expiry ordering (spy backend proves backend NOT called before sig/expiry checks pass), wrong nonce, policy tier mapping, bad-proof escalation, backend registry.
