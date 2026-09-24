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

- **The published journey-helper roll-call was short by `run_query` (K-1696).** The lists name it now, and the two «helpers are available» tests are held to the module rather than to themselves.

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.

### Added

- Initial skeleton.
- `Kiosk::TestHelpers` extended with the Minitest convenience surface — `include Kiosk::TestHelpers` in a `Minitest::Test` subclass mixes in the journey DSL and the `assert_rls_denied` / `assert_quota_exceeded` assertions.
- Negative-form assertions `refute_rls_denied` and `refute_quota_exceeded` plus the spec-DSL `must_raise_*` / `wont_raise_*` analogues.

### Notes on the three-gem split

The journey-test DSL itself lives in the new `kiosk-test-support` gem (a sibling of this one); `kiosk-rls-minitest` is intentionally thin (~200 LOC) and only contains the Minitest convenience include and the assertion methods. The RSpec analogue lives in `kiosk-rls-rspec`. The split avoids duplication and prevents one harness from depending on the other.
