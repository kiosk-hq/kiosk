# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial implementation.
- `Kiosk::Reputation::Backends` — algorithm registry: `register` / `fetch` / `known` / `reset!`.
- `Kiosk::Reputation::Backends.valid_params?(alg, params)` — the mint-time seam a gate asks before issuing a challenge (K-843). Duck-typed and opt-in: it answers `false` only when a registered backend says so itself, and `true` for an unregistered algorithm or one that expresses no opinion, so it can never invent a refusal.
- `Kiosk::Reputation::Challenge` — stateless, request-bound wire challenge: `issue` / `verify` with anti-DoS cheap-before-expensive ordering (HMAC sig + expiry before backend eval).
- `Kiosk::Reputation::Factors` — immutable Data class with all-nullable reputation fields; `.empty` constructor.
- `Kiosk::Reputation::Policy` — base class (never challenge); providers subclass or replace.
- `Kiosk::Reputation::Policies::RateAndReputation` — shipped EXAMPLE policy: escalates by Equihash proof COUNT (count-curve; no continuous difficulty dial) on high request rate, zero purchases, and bad-proof history; providers are expected to replace it.
- RSpec suite covering: challenge round-trip, tampered fields, fingerprint mismatch, wrong secret, expiry ordering (spy backend proves backend NOT called before sig/expiry checks pass), wrong nonce, policy tier mapping, bad-proof escalation, backend registry.
