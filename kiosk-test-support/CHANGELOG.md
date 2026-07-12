# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Dropped the `kiosk-rls` dependency (RLS is opt-in now). This gem never
  used `Kiosk::RLS` constants — `Errors::RLSDenied` is its own class and
  stays.

### Added

- Initial skeleton.
- `Kiosk::TestHelpers::Journey` module — the journey-test DSL: `as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`.
- Pluggable executor contract — `Kiosk::TestHelpers.executor=` accepts any object responding to `with_identity(identity, &block)`, `query(sql)`, `run_action(name, args)`, `pay_action(name, args)`, `seed(table, attrs, count:)`. Default is unset; raises `Kiosk::TestHelpers::ExecutorNotConfigured` until wired.
- `Kiosk::TestHelpers::NullExecutor` — records calls into an inspectable array; queues seeded results. Used by this gem's own specs and by `kiosk-rls-rspec` / `kiosk-rls-minitest` self-tests until `kiosk-server` ships a real `TestExecutor`.
- `Kiosk::TestHelpers::Errors` — `RLSDenied`, `QuotaExceeded`, `ExecutorNotConfigured`. Used by the framework-specific matchers / assertions.

### Notes on the three-gem split

The journey-test DSL was originally scoped to live inside `kiosk-rls-rspec` and `kiosk-rls-minitest`. We split the shared module out into this third gem so both harness gems can `include Kiosk::TestHelpers::Journey` without duplication or one harness depending on the other. The two harness gems remain ≤200 LOC each (framework wiring only); the shared DSL fits in ≤400 LOC here.
