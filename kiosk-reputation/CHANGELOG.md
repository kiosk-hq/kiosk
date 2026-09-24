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
