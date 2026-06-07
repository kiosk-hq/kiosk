# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton — `Kiosk::UserIdentityProviders::Devise` extending `Kiosk::UserIdentityProviders::Base` (spec §6.4).
- `#verify(request)` reads `current_user` from a Rails controller (the common case — kiosk-server passes `self`) and returns a `Kiosk::Identity` with `actor: "human"`. Returns `nil` when `current_user` is nil — which covers unauthenticated, locked, and unconfirmed users uniformly since Devise's `active_for_authentication?` already gates `current_user`.
- Tiny Rack-env compatibility shim: if the request is a Hash with `"warden"`, the user is read from `env["warden"].user`.
- Role resolution per spec §6.2: `user.kiosk_role` if defined, else first of `Kiosk.configuration.roles`. Raises `Kiosk::UserIdentityProviders::Devise::ConfigurationError` with a help-style message when both fall through.
- Honours `Kiosk.configuration.user_id_column` (default `:id`).
- Inherits the default `user_active?` from {Kiosk::UserIdentityProviders::Base} — embedded mode relies on Devise's per-request `active_for_authentication?` hook rather than an opt-in callback.

### Design decisions

- **No hard `devise` runtime dependency.** The adapter only calls `request.current_user`; the provider's installed Devise satisfies the requirement. Documenting this in `README.md` is cleaner than forcing a Bundler constraint that doesn't match reality (kiosk-server's executor injects the controller — Devise itself isn't a constructor argument).
- **No test-time `devise` dependency.** Tests use a stub `current_user`; loading Devise just to verify a one-line read would be ceremony.

### Out of scope for first release

- `Kiosk::HumanContext` cross-channel session mixing (spec §8.6).
- Full Rails controller integration test (needs a host app — lands with kiosk-server's request specs).
- `kiosk-devise` — the broader Devise integration with kiosk-server's controllers, generators, and approval-form partial (spec §15.2).
