# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial implementation.
- `Kiosk::Reputation::Backends` — algorithm registry: `register` / `fetch` / `known` / `reset!`.
- `Kiosk::Reputation::Challenge` — stateless, request-bound wire challenge: `issue` / `verify` with anti-DoS cheap-before-expensive ordering (HMAC sig + expiry before backend eval).
- `Kiosk::Reputation::Factors` — immutable Data class with all-nullable reputation fields; `.empty` constructor.
- `Kiosk::Reputation::Policy` — base class (never challenge); providers subclass or replace.
- `Kiosk::Reputation::Policies::RateAndReputation` — shipped EXAMPLE policy: escalates by Equihash proof COUNT (count-curve; no continuous difficulty dial) on high request rate, zero purchases, and bad-proof history; providers are expected to replace it.
- RSpec suite covering: challenge round-trip, tampered fields, fingerprint mismatch, wrong secret, expiry ordering (spy backend proves backend NOT called before sig/expiry checks pass), wrong nonce, policy tier mapping, bad-proof escalation, backend registry.
