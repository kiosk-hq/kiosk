# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton.
- `Kiosk::RLS::Policy` value type (Data class): name, action, using, check; action ∈ {select, insert, update, delete, all}.
- `Kiosk::RLS::Table` mutable builder used inside `enable_rls_on` blocks.
- `Kiosk::RLS::Emitter` — pure SQL-DDL generation (ENABLE ROW LEVEL SECURITY, GRANT, CREATE POLICY, COMMENT ON TABLE, DROP POLICY, ALTER POLICY ... RENAME TO).
- `Kiosk::RLS::DSL` — `enable_rls_on`, `add_kiosk_policy_to`, `change_kiosk_policy_on`, `remove_kiosk_policy_from`, `rename_kiosk_policy_on` (spec §7.3).
- `Kiosk::RLS::ConfigurationExtension` — adds `app_role`, `system_role`, `schema` to `Kiosk::Configuration` with lazy defaults.
- RSpec suite covering policy validation, builder semantics, SQL emission, DSL with fake executor, config extension.

### Out of scope for first release

- `rake kiosk:rls:{show,check}` rake tasks (need PG connection — land later).
- `ActiveRecord::Migration` auto-injection (`require "kiosk/rls/migration"`).
- Schema-separated view DSL (`bin/rails g kiosk:view` — deferred to v1.1 per spec §7.8).
