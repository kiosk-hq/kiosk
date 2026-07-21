# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- `Kiosk::AgentIdentityProviders::Base` doc now states plainly that the
  bundled `DefaultAgentIdp` ships as the default (zero config) and that
  fronting an external agent-identity issuer is a PLANNED seam — no external
  `kiosk-agent-idp-*` adapter ships yet (was overclaiming shipped adapters).
- `Kiosk::Configuration` gains `schema` (default "kiosk") and `app_role`
  (default "app_role") — moved from kiosk-rls; they are deployment
  vocabulary shared by kiosk-server, not RLS-specific.

### Added

- Initial skeleton.
- Value types: `Kiosk::Identity`, `Kiosk::Mandate::IntentMandate` / `CartMandate` / `PaymentMandate`.
- Abstract base classes: `AgentIdentityProviders::Base`, `UserIdentityProviders::Base`, `PaymentProviders::Base`.
- GUC namespace constants (`Kiosk::GUC`) with the four well-known names (`current_user_id`, `current_role`, `current_actor`, `current_agent_id`) and a composer (`Kiosk::GUC.for`).
- Configuration object (`Kiosk::Configuration`) and `Kiosk.configure { |c| ... }` block.
- Protocol-version surface (`Kiosk::Protocol`): `API_VERSION`, `MIN_CLIENT`, response-header names, default mount path.
