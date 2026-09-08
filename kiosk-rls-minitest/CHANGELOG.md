# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.

### Added

- Initial skeleton.
- `Kiosk::TestHelpers` extended with the Minitest convenience surface — `include Kiosk::TestHelpers` in a `Minitest::Test` subclass mixes in the journey DSL and the `assert_rls_denied` / `assert_quota_exceeded` assertions.
- Negative-form assertions `refute_rls_denied` and `refute_quota_exceeded` plus the spec-DSL `must_raise_*` / `wont_raise_*` analogues.

### Notes on the three-gem split

The journey-test DSL itself lives in the new `kiosk-test-support` gem (a sibling of this one); `kiosk-rls-minitest` is intentionally thin (~200 LOC) and only contains the Minitest convenience include and the assertion methods. The RSpec analogue lives in `kiosk-rls-rspec`. The split avoids duplication and prevents one harness from depending on the other.
