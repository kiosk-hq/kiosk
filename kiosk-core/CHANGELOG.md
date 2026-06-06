# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton.
- Value types: `Kiosk::Identity`, `Kiosk::Mandate::IntentMandate` / `CartMandate` / `PaymentMandate`, `Kiosk::Event`.
- Abstract base classes: `AgentIdentityProviders::Base`, `UserIdentityProviders::Base`, `PaymentProviders::Base`, `CredentialBrokers::Base`, `NotificationAdapter::Base`.
- GUC namespace constants (`Kiosk::GUC`) with the four well-known names (`current_user_id`, `current_role`, `current_actor`, `current_agent_id`) and a composer (`Kiosk::GUC.for`).
- Configuration object (`Kiosk::Configuration`) and `Kiosk.configure { |c| ... }` block.
- Protocol-version surface (`Kiosk::Protocol`): `API_VERSION`, `MIN_CLIENT`, response-header names, well-known path, default mount path.
