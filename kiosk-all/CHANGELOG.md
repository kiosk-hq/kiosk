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

## [0.5.0] — 2026-09-26

### Changed

- README: the adapter section names the two adapter gems that ship and the base classes to subclass, instead of forecasting adapters that do not exist (K-1673).
- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- `kiosk-rls` is no longer bundled — RLS is opt-in. Add `gem "kiosk-rls"`
  explicitly if you use `enable_rls_on` in migrations.

### Added

- Initial skeleton.
- Meta-gem entry point (`lib/kiosk-all.rb`) that requires `kiosk` and `kiosk/server`.
- Runtime dependencies on `kiosk-core`, `kiosk-server` (production data plane only).

### Deliberately not included

- `kiosk-test-support`, `kiosk-rls-rspec`, `kiosk-rls-minitest` — test-only; host adds one to the dev/test group of its Gemfile per its test stack.
- Adapter gems (`kiosk-user-idp-*`, `kiosk-pay-*`) — providers pick per market and stack; a single umbrella would pull in unused dependencies.
