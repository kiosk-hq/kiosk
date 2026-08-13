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

- **A BLOCKED verdict now names the gate it proved.** `verdict_from` takes `expect:` / `expect_code:`, so a scenario demands the status and denial code that constitute a refusal of ITS attack instead of accepting any of 401/402/403 interchangeably; the Runner prints the status on the BLOCKED line, and `all_blocked?` refuses to go green on a battery in which nothing was exercised. What a green battery means is stricter than it was: verdicts that used to pass on an unrelated gate's refusal, on a crash, or on a query that was never answered now fail.
- The registration gate the client solves is Equihash, not the SHA256 hashcash the first version assumed — client, docstrings and gemspec now describe the shipped gate, and the dead hashcash helper is gone.
- The proof travels in a `Kiosk-PoW` request header as raw JSON rather than as a body field.
- `jwt` widened to `>= 2.0, < 4.0` so hosts on jwt 3.x can run the harness.

### Fixed

- Six ways a scenario could report a pass it had not earned: `CrossTenantRead` scored a 404/402/500 on B's query as isolation and had no control proving the query returns anything for its owner; the two registration scenarios passed against a server that 404s every path; the KYC scenarios discarded the payment they staged, so the payment gate answered in the KYC gate's name; `PayForOtherUseSelf` reported a card decline or an expired token as the ownership gate and never attempted the attack; and an all-skip battery exited 0. Each now asserts what it staged and names the gate it demands.
- A crash can no longer masquerade as enforcement through the denial-code path: `Kiosk::Redteam.blocked?` applies its 5xx/connection-error rule to the `error.code` branch as well, which had none.
- A skipped scenario reports a real skipped state instead of a pass, an inapplicable scenario is asserted as such, and `bad_request` no longer counts as "blocked" — three ways the harness could previously report green without having proved anything.
- The client locates the Equihash solver through `Kiosk::Pow::Equihash.solver_path`, with `kiosk-pow-equihash` now a declared runtime dependency — the previous monorepo-relative filesystem reach meant an installed `kiosk-redteam` raised `Errno::ENOENT` the first time a scenario had to solve a registration challenge.
