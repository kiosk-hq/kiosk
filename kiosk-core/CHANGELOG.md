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

- `Kiosk::Protocol` gains `HEADER_TIMEZONE` (`Kiosk-Timezone`), the request header a caller declares its own clock in.
- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- `Kiosk::AgentIdentityProviders::Base` doc now states plainly that the
  bundled `DefaultAgentIdp` ships as the default (zero config) and that
  fronting an external agent-identity issuer is a PLANNED seam — no external
  `kiosk-agent-idp-*` adapter ships yet (was overclaiming shipped adapters).
- `Kiosk::Configuration` gains `schema` (default "kiosk") and `app_role`
  (default "app_role") — moved from kiosk-rls; they are deployment
  vocabulary shared by kiosk-server, not RLS-specific.

### Added

- `Kiosk::UuidCheck` — canonical-uuid shape guard for identifiers that arrive on the wire, with `PATTERN` (the runtime predicate) and `JSON_SCHEMA_PATTERN` (the same shape for a verb descriptor's `input_schema`) beside each other so the declared contract and the enforced one cannot drift. An origin that lets a malformed id reach a Postgres `uuid` cast answers either a 500 leaking SQL internals or a wrong ownership refusal; both are the origin's bug reported as something else.
- Initial skeleton.
- Value types: `Kiosk::Identity`, `Kiosk::Mandate::IntentMandate` / `CartMandate` / `PaymentMandate`.
- Abstract base classes: `AgentIdentityProviders::Base`, `UserIdentityProviders::Base`, `PaymentProviders::Base`.
- GUC namespace constants (`Kiosk::GUC`) with the four well-known names (`current_user_id`, `current_role`, `current_actor`, `current_agent_id`) and a composer (`Kiosk::GUC.for`).
- Configuration object (`Kiosk::Configuration`) and `Kiosk.configure { |c| ... }` block.
- Protocol-version surface (`Kiosk::Protocol`): `API_VERSION`, `MIN_CLIENT`, response-header names, default mount path.
