# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- `kiosk-rls` is no longer bundled — RLS is opt-in. Add `gem "kiosk-rls"`
  explicitly if you use `enable_rls_on` in migrations.

### Added

- Initial skeleton.
- Meta-gem entry point (`lib/kiosk-all.rb`) that requires `kiosk`, `kiosk/rls`, and `kiosk/server`.
- Runtime dependencies on `kiosk-core`, `kiosk-rls`, `kiosk-server` (production data plane only).

### Deliberately not included

- `kiosk-test-support`, `kiosk-rls-rspec`, `kiosk-rls-minitest` — test-only; host adds one to the dev/test group of its Gemfile per its test stack.
- Adapter gems (`kiosk-user-idp-*`, `kiosk-pay-*`, `kiosk-credentials-*`) — providers pick per market and stack; a single umbrella would pull in unused dependencies.
