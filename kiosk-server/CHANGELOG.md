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

### Out of scope for first release

- Controllers (`/kiosk/exec`, OAuth 2.1 surface, agent registration endpoints, `/kiosk/events`) — follow-up.
- `Kiosk::Executor` and per-request transaction with `SET LOCAL` GUCs — follow-up.
- `bin/rails g kiosk:install` generator — follow-up.
- `rake kiosk:doctor` — follow-up.
- Full Rails-engine integration tests (requires booting a host app) — follow-up.
