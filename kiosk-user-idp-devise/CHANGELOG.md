# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial skeleton — `Kiosk::UserIdentityProviders::Devise` extending `Kiosk::UserIdentityProviders::Base`.
- `#verify(request)` reads the signed-in user from the request's Warden proxy (`request.env["warden"].user` — the shipped wire, where kiosk-server's `IdentityResolution.resolve` passes an `ActionDispatch::Request`) and returns a `Kiosk::Identity` with `actor: "human"`. Returns `nil` when no user is signed in — which covers unauthenticated, locked, and unconfirmed users uniformly since Devise's `active_for_authentication?` already gates the Warden user.
- Also accepts a controller-shaped object exposing `#current_user`, and a bare Rack `env` Hash carrying `env["warden"]`, for hosts that pass either directly.
- Role resolution: `user.kiosk_role` if defined, else first of `Kiosk.configuration.roles`. Raises `Kiosk::UserIdentityProviders::Devise::ConfigurationError` with a help-style message when both fall through.
- Honours `Kiosk.configuration.user_id_column` (default `:id`).
- Inherits the default `user_active?` from {Kiosk::UserIdentityProviders::Base} — embedded mode relies on Devise's per-request `active_for_authentication?` hook rather than an opt-in callback.

### Design decisions

- **No hard `devise` runtime dependency.** The adapter only reads the request's Warden user (`request.env["warden"].user`); the provider's installed Devise satisfies the requirement. Documenting this in `README.md` is cleaner than forcing a Bundler constraint that doesn't match reality (kiosk-server's `IdentityResolution.resolve` passes an `ActionDispatch::Request` — Devise itself isn't a constructor argument).
- **No test-time `devise` dependency.** Tests use a stub `current_user`; loading Devise just to verify a one-line read would be ceremony.

### Out of scope for first release

- `Kiosk::HumanContext` cross-channel session mixing.
- Full Rails controller integration test (needs a host app — lands with kiosk-server's request specs).
- `kiosk-devise` — the broader Devise integration with kiosk-server's controllers, generators, and approval-form partial.
