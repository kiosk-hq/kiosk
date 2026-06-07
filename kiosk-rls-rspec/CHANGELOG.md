# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton.
- RSpec wiring: `type: :kiosk_journey` and `type: :kiosk_agent` metadata auto-include `Kiosk::TestHelpers::Journey` into example groups.
- Matchers: `be_rls_denied`, `be_quota_exceeded` — succeed when the wrapped block raises the corresponding `Kiosk::TestHelpers::Errors` class.
- `Kiosk::RLSRSpec.install!` — opt-in API for non-Rails apps to register the wiring in their own RSpec config.

### Notes on the three-gem split

The journey-test DSL itself lives in the new `kiosk-test-support` gem (a sibling of this one); `kiosk-rls-rspec` is intentionally thin (~200 LOC) and only contains the RSpec configuration hook and matchers. The Minitest analogue lives in `kiosk-rls-minitest`. The split avoids duplication and prevents one harness from depending on the other.
