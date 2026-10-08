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

- **The published journey-helper roll-call was short by `run_query` (K-1696).** The lists name it now, and the two «helpers are available» tests are held to the module rather than to themselves.

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.

### Added

- Initial skeleton.
- `Kiosk::TestHelpers` extended with the Minitest convenience surface — `include Kiosk::TestHelpers` in a `Minitest::Test` subclass mixes in the journey DSL and the `assert_rls_denied` / `assert_quota_exceeded` assertions.
- Negative-form assertions `refute_rls_denied` and `refute_quota_exceeded` plus the spec-DSL `must_raise_*` / `wont_raise_*` analogues.

### Notes on the three-gem split

The journey-test DSL itself lives in the new `kiosk-test-support` gem (a sibling of this one); `kiosk-rls-minitest` is intentionally thin (~200 LOC) and only contains the Minitest convenience include and the assertion methods. The RSpec analogue lives in `kiosk-rls-rspec`. The split avoids duplication and prevents one harness from depending on the other.
