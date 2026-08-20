# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **A TOLLED VERB CAN NOW BE ATTACKED (K-760).** `#query`, `#run`, `#pay` and `#pay_raw` route their answer through one shared, bounded 402-PoW retry — the same `Client#with_pow_retry` registration uses — instead of leaving the solve branch inlined in `#register_raw` where only registration could reach it. A toll is a price, not a refusal (K-736), so an attacker pays it; a harness that could not pay it could not run the attack at all. Measured against getgrocery with its catalog toll ON (`KIOSK_POW_DEMO=1`): before, the battery ABORTED on its first scenario (`catalog returned empty`) and produced no verdicts; after, 17 BLOCKED / 3 SKIPPED / 0 BREACH, byte-identical to the untolled run. Exactly ONE solve-and-resend per call, never a loop: a re-demanded toll comes back flagged `pow_retried` and reads as a could-not-test verdict that says the toll was already paid, which is a statement about the provider rather than about this gem. The retry re-sends the IDENTICAL request — `#pay` signs its mandates once and reuses the body, because the challenge binds to a fingerprint of method + verb + body and a re-signed mandate would be a different request.

- The client speaks protocol 0.4: `#query` is `GET <endpoint>/<query-name>` with its arguments in the query string, `#run` is `POST <endpoint>/<action-name>` with the arguments as the whole body, and there is no `name` field on the wire. Error codes are read off the top level of an RFC 9457 problem document rather than out of the retired `error` envelope.

### Fixed

- `Scenario#rows_from` read only the paginated `{rows:, next:}` shape, so a non-paginating query's BARE ARRAY answer — the ordinary one on the 0.4 wire — decoded as no rows at all. `ForgedUserId`'s ownership check would then have read "not leaked" and scored a **vacuous BLOCKED** against an origin it never tested.
- `ForgedUserId#extract_id` read the deleted 0.3 `value` wrapper, so on any real origin it found no resource id and every run ended "cannot confirm ownership was enforced".
- `ForgedUserId` now scores the typed `400 bad_request` a 0.4 origin answers — the refusal that NAMES the injected `user_id`, because a verb whose principal comes from the token does not declare it — as BLOCKED. Without that branch the scenario reported a BREACH against a provider doing exactly the right thing. The check is in the scenario, not in `blocked?`: what makes this 400 evidence is that it names the property we injected, which a generic predicate cannot see.

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
- Neither can a toll: `blocked?` counted a bare HTTP 402 as "explicit auth/authz rejection" although kiosk-server shares that status between `pow_required`, `payment_setup_required` and `payment_failed` — so a tolled verb printed `BLOCKED ✓ … (HTTP 402)` for an attack the harness never ran, since it solves proof-of-work only during registration. A 402 (and a `pow_required` envelope on any status) now yields a could-not-test verdict that names which of the three answered and fails the battery instead of passing it; a scenario that genuinely means a payment gate names the code it accepts with `verdict_from(expect_code:)`.
- A skipped scenario reports a real skipped state instead of a pass, an inapplicable scenario is asserted as such, and `bad_request` no longer counts as "blocked" — three ways the harness could previously report green without having proved anything.
- The client locates the Equihash solver through `Kiosk::Pow::Equihash.solver_path`, with `kiosk-pow-equihash` now a declared runtime dependency — the previous monorepo-relative filesystem reach meant an installed `kiosk-redteam` raised `Errno::ENOENT` the first time a scenario had to solve a registration challenge.
