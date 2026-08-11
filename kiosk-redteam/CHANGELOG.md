# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Kiosk::Redteam::Client` — HTTP client for the wire surface an attacker sees: agent register/login (solving the Equihash registration toll), KYC attestation, and the `query` / `run` / `pay` verbs with RS256 mandate signing.
- `Kiosk::Redteam::Scenario` / `Verdict` / `Runner` — the harness. A scenario runs one hostile flow and returns a `Verdict` (blocked / skipped, status, detail); a scenario that finds a real breach fails loudly rather than reporting a pass.
- `Kiosk::Redteam::Principal` / `Response` — the value types scenarios work with: a registered agent identity carrying its RSA key so mandates can be signed or forged, and a parsed HTTP response.
- `Kiosk::Redteam::Profile` — per-provider parameterisation (PoW difficulty, KYC requirement, the queries and actions to attack, mandate builders), so one scenario library runs against any Kiosk provider.
- Generic attack scenario library: cross-tenant read, forged user id, privilege self-selection, mandate principal swap, mandate replay, token tampering, missing / expired / forged KYC, unpaid gated action, pay-for-other-use-self, spent-resource reuse, and registration without PoW.
- `base64` declared as a runtime dependency — `scenario.rb` and `scenarios/privilege_self_selection.rb` require it at load time, and until then it arrived only by accident, as a transitive dependency of `jwt` (it stopped being a default gem in Ruby 3.4).

### Changed

- The registration gate the client solves is Equihash, not the SHA256 hashcash the first version assumed — client, docstrings and gemspec now describe the shipped gate, and the dead hashcash helper is gone.
- The proof travels in a `Kiosk-PoW` request header as raw JSON rather than as a body field.
- `jwt` widened to `>= 2.0, < 4.0` so hosts on jwt 3.x can run the harness.

### Fixed

- A skipped scenario reports a real skipped state instead of a pass, an inapplicable scenario is asserted as such, and `bad_request` no longer counts as "blocked" — three ways the harness could previously report green without having proved anything.
