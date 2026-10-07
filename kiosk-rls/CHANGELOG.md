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

- **The README stopped forecasting `rake kiosk:rls:{show,check}`, which nothing defines (K-1700).** It now points at `psql`, which answers both questions today.

- **The rubygems blurb listed the DDL this gem emits and left out FORCE ROW LEVEL SECURITY (K-1697).** Without it Postgres exempts the table owner and RLS is a no-op.
- **`system_role` stops pointing at an Action-DSL escalation that has not shipped (K-1695).** Its live caveat now carries the measurement behind it.

- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- Now truly opt-in: no longer a dependency of kiosk-server, kiosk-all, or
  kiosk-test-support. `ConfigurationExtension` now contributes only
  `system_role`; `schema` and `app_role` moved to kiosk-core,
  `enforce_db_role` to kiosk-server.

### Added

- `Kiosk::RLS::Railtie` — a Rails host gets the five migration verbs on
  `ActiveRecord::Migration` from the gem itself. The README used to tell the
  host to write `ActiveRecord::Migration.include(Kiosk::RLS::DSL)` in an
  initializer; that is an application patching a framework class on a gem's
  behalf, and it is gone. Non-Rails hosts still include `Kiosk::RLS::DSL`
  wherever they answer `#execute(sql)`. (K-504)
- Initial skeleton.
- `Kiosk::RLS::Policy` value type (Data class): name, action, using, check; action ∈ {select, insert, update, delete, all}.
- `Kiosk::RLS::Table` mutable builder used inside `enable_rls_on` blocks.
- `Kiosk::RLS::Emitter` — pure SQL-DDL generation (ENABLE ROW LEVEL SECURITY, GRANT, CREATE POLICY, COMMENT ON TABLE, DROP POLICY, ALTER POLICY ... RENAME TO).
- `Kiosk::RLS::DSL` — `enable_rls_on`, `add_kiosk_policy_to`, `change_kiosk_policy_on`, `remove_kiosk_policy_from`, `rename_kiosk_policy_on`.
- `Kiosk::RLS::ConfigurationExtension` — adds the RLS-only `system_role` to `Kiosk::Configuration` with a lazy default.
- RSpec suite covering policy validation, builder semantics, SQL emission, DSL with fake executor, config extension.

### Out of scope for first release

- `rake kiosk:rls:{show,check}` rake tasks (need PG connection — land later).
- Schema-separated view DSL (`bin/rails g kiosk:view` — deferred to v1.1).
