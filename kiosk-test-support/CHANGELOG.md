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

- **The published journey-helper roll-call was short by `run_query` (K-1696).** The lists name it now, and the two «helpers are available» tests are held to the module rather than to themselves.

- The route conformance check no longer special-cases the engine's refusal controller, which no longer exists: a declared verb whose route is missing is reported as declared-and-never-routed, which is what every caller now meets as an ordinary 404.
- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- Dropped the `kiosk-rls` dependency (RLS is opt-in now). This gem never
  used `Kiosk::RLS` constants — `Errors::RLSDenied` is its own class and
  stays.

### Added

- `Kiosk::TestHelpers::Conformance` — four checks an origin runs against itself for the four properties the protocol makes normative of it: that its routes resolve, that a verb executes, that a query answers the shape it declared, and that data access is scoped to the authenticated principal. Inert until an origin is wired (`Conformance.origin=`); `kiosk-server` ships the real one.
- Two adapters, loaded by explicit require so this gem still depends on no test framework: `kiosk/test_helpers/conformance/minitest` (`assert_kiosk_verbs_routed`, `assert_kiosk_verb_executes`, `assert_kiosk_answer_matches_declared_schema`, `assert_kiosk_scoped_to_principal`) and `kiosk/test_helpers/conformance/rspec` (`have_a_route_for_every_verb`, `execute_as_a_kiosk_verb`, `answer_its_declared_schema`, `be_scoped_to_principal`). Both render the same failure sentence.
- `Kiosk::TestHelpers::Conformance::NullOrigin` — the zero-dependency reference implementation of the origin contract, for unit-shaped tests with no Rails and no database.
- `Journey#run_query(name, **args)` and a matching `run_query` on the executor contract. `query` takes SQL; without this, a declared `kind :query` verb was reachable through nothing.
- `Errors::OriginNotConfigured` and `Errors::SchemaValidatorMissing`, both carrying wiring instructions.

- Initial skeleton.
- `Kiosk::TestHelpers::Journey` module — the journey-test DSL: `as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`.
- Pluggable executor contract — `Kiosk::TestHelpers.executor=` accepts any object responding to `with_identity(identity, &block)`, `query(sql)`, `run_action(name, args)`, `pay_action(name, args)`, `seed(table, attrs, count:)`. Default is unset; raises `Kiosk::TestHelpers::Errors::ExecutorNotConfigured` until wired.
- `Kiosk::TestHelpers::NullExecutor` — records calls into an inspectable array; queues seeded results. Used by this gem's own specs and by `kiosk-rls-rspec` / `kiosk-rls-minitest` self-tests; `kiosk-server` ships the real `Kiosk::Server::TestExecutor` for production-shaped tests.
- `Kiosk::TestHelpers::Errors` — `RLSDenied`, `QuotaExceeded`, `ExecutorNotConfigured`. Used by the framework-specific matchers / assertions.

### Notes on the three-gem split

The journey-test DSL was originally scoped to live inside `kiosk-rls-rspec` and `kiosk-rls-minitest`. We split the shared module out into this third gem so both harness gems can `include Kiosk::TestHelpers::Journey` without duplication or one harness depending on the other. The two harness gems remain ≤200 LOC each (framework wiring only); the shared DSL fits in ≤400 LOC here.
