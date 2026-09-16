# Changelog

**Keep the entries short, always under 200 characters and one-two sentences.
Only keep the essence of the change. git commit messages will keep the details.
In the CHANGELOG, only keep the essence.** (Phil, 2026-09-11.) The rule binds
every `CHANGELOG.md` in this repository; `bin/check-changelog` holds it on
entries that are new against its declared baseline commit, and never on the
entries already below.

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Three sentences forecast a `kiosk-agent-test` gem that does not exist (K-1695).** They say what the `:kiosk_agent` tag IS instead — the same DSL, not a second mode.

- **The published journey-helper roll-call was short by `run_query` (K-1696).** The lists name it now, and the two «helpers are available» tests are held to the module rather than to themselves.

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.

### Added

- Initial skeleton.
- RSpec wiring: `type: :kiosk_journey` and `type: :kiosk_agent` metadata auto-include `Kiosk::TestHelpers::Journey` into example groups.
- Matchers: `be_rls_denied`, `be_quota_exceeded` — succeed when the wrapped block raises the corresponding `Kiosk::TestHelpers::Errors` class.
- `Kiosk::RLSRSpec.install!` — opt-in API for non-Rails apps to register the wiring in their own RSpec config.

### Notes on the three-gem split

The journey-test DSL itself lives in the new `kiosk-test-support` gem (a sibling of this one); `kiosk-rls-rspec` is intentionally thin (~200 LOC) and only contains the RSpec configuration hook and matchers. The Minitest analogue lives in `kiosk-rls-minitest`. The split avoids duplication and prevents one harness from depending on the other.
