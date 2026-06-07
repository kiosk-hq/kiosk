# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton.
- `Kiosk::Server::ConfigurationExtension` — adds `mount_path`, `capabilities`, `owner`, `min_client` to `Kiosk::Configuration` with lazy defaults.
- `Kiosk::Server::WellKnown` — pure-Ruby builder for `/.well-known/kiosk.json` per spec §3.4. Returns Hash or JSON string. Validates `issuer` is set.
- `Kiosk::Server::Headers` — composes the three Kiosk response headers (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`).
- `Kiosk::Server::HeadersMiddleware` — Rack middleware that injects the headers on responses whose path starts with the configured mount path.
- `Kiosk::Server::SchemaDefinitions` — pure SQL generators for canonical migrations 001-004 (kiosk schema + current_*() helpers, agents/agent_tokens/agent_mappings, actions/action_log, reservations); typed against the configured user-id type (`:uuid`, `:bigint`, `:integer`, `:text`).
- `Kiosk::Server::Engine` — Rails engine declaration (conditionally loaded when `Rails::Engine` is defined). Auto-mounts `HeadersMiddleware` in the host app's stack.

- **Executor and Errors layer** (follow-up addition within Unreleased):
  - `Kiosk::Server::Errors` hierarchy — `Base`, `BadRequest`, `Unauthenticated`, `Forbidden`, `RLSDenied`, `NotFound`, `QuotaExceeded`, `ActionFailed` — each carrying `CODE`, `EXIT_CODE`, `HTTP_STATUS` per spec §5.2; `Base#to_envelope` serialises `ok:false` body with `code/message/hint/query_id` (nil fields dropped).
  - `Kiosk::Server::Result` Data class — `:rows`/`:value`/`:stream` envelope shapes; `to_envelope` for JSON serialisation; `query_id` optional.
  - `Kiosk::Server::SessionContext` — opens a transaction on any connection responding to `#transaction`/`#execute`, emits `SET LOCAL` for the four canonical GUCs per spec §6.3; skips `agent_id` GUC for non-agent actors; respects configured `guc_namespace`.
  - `Kiosk::Server::Actions` — minimal process-wide registry (`register(name, &block)`, `fetch(name)`, `known`, `reset!`); raises `Errors::NotFound` on unknown.
  - `Kiosk::Server::Executor` — six-verb dispatch (`sql`, `run`, `pay`, `schema`, `help`, `events`); `sql` + `run` fully working against any conforming connection; `pay`/`schema`/`help`/`events` raise `NotImplementedError` pointing at the follow-up release that adds them.
  - `Kiosk::Server::ExecController` — Rails controller (conditionally defined when `ActionController::API` is loaded); resolves identity via configured `agent_idp` then `user_idp`, parses JSON body, calls `Executor`, serialises envelope with HTTP status + Kiosk headers.

### Out of scope for first release

- OAuth 2.1 surface (token/authorize/revoke/introspect endpoints) — follow-up.
- Full `Kiosk::Action` DSL (`description`, `accepts`, `requires_payment`, `escalate_to :system`) — current `Actions` registry is a minimal callable map.
- `pay` verb implementation (lands with `kiosk-pay-stripe`, M4).
- `schema` / `help` verbs (need Postgres introspection of catalog + COMMENT ON).
- `events` verb (NDJSON streaming per §5.8).
- `bin/rails g kiosk:install` generator — follow-up.
- `rake kiosk:doctor` — follow-up.
- Full Rails-engine integration tests (requires booting a host app) — follow-up.
- Satellite-mode connection-pool plumbing per spec §7.7 (currently `ExecController#connection_for` uses `ActiveRecord::Base.connection`).
