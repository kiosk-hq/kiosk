# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **kiosk-server declares Rails.** New runtime dependencies: `railties`,
  `actionpack`, `activerecord` and `activesupport`, all `~> 8.1` — the four
  components the gem references. Deliberately not the `rails` meta-gem: nothing
  here touches Action Mailer, Action Cable, Active Job, Active Storage, Action
  Text or Action Mailbox. The engine and the nine controllers no longer hide
  behind `if defined?(::ActionController::API)` / `if defined?(::Rails::Engine)`
  — `require "kiosk/server"` defines all ten unconditionally, so a missing
  framework is a LoadError at require time rather than a NameError at request
  time. Consequences: `Kiosk.configuration.device_authorization_store` always
  lazy-defaults to the durable ActiveRecord adapter (it already did in every
  Rails host), and `TestExecutor` no longer offers an "ActiveRecord absent"
  error path. Rails < 8.1 is untested and therefore not claimed (K-495, T-052).
- **PoW proof moves to the `Kiosk-PoW` request header.** `WireController` and
  `AuthController#register` now read the proof(s) from the `Kiosk-PoW` request
  header as raw JSON (`HTTP_KIOSK_POW`) instead of a `pow` body field (ADR-0022,
  K-483). The parser dual-accepts a single proof, a JSON array, repeated header
  lines (Rack `\n`-joined), or a proxy comma-combined value, flattening all into
  one proofs list — so the tolled `schema` GET can carry its proof (a GET has no
  body). The body is now purely verb args (the challenge fingerprint is over the
  plain body, unchanged on retry); the old body-pow path is removed (no
  back-compat). A malformed header is a `bad_request` (400) with a hint;
  `RequestValidation` validates each parsed proof; the 402 keeps its
  `WWW-Authenticate: Kiosk-PoW` header (completes T-022).
- **Install-generator honesty.** The `kiosk:install` initializer template no longer advertises a nonexistent `MyCustomAgentIdp`; it now states plainly that the bundled kiosk-pop agent-IdP is the default (zero config), that fronting an external agent-identity issuer means subclassing `Kiosk::AgentIdentityProviders::Base` (a planned seam, none shipped), and that `c.user_idp` binds a human account with `kiosk-user-idp-devise` as the worked example. Template text only — no generated behavior change.
- **RLS is now opt-in.** kiosk-server no longer depends on or requires
  `kiosk-rls`. Hosts that want DB-level row enforcement add
  `gem "kiosk-rls"` themselves (see the kiosk-rls README). Config moves:
  `schema` and `app_role` now live in kiosk-core's `Kiosk::Configuration`;
  `enforce_db_role` in kiosk-server's extension. No wire-surface change.

### Added

- **Opt-in request-shape validation.** A new `c.validate_requests` flag (default off; byte-identical old behaviour when off) makes `WireController` validate a PRESENT `pow` field against the vendored normative PoW JSON Schema at the wire choke point — BEFORE the gate consumes it — and reject a malformed shape with a `bad_request` (400) carrying a hint naming the expected `pow.proofs[]` form. This closes the K-479 silent-re-challenge loop (a `pow: {solutions:[…]}` whose proofs the gate couldn't parse yielded a fresh 402 on every retry with no diagnostic). It is a shape check IN FRONT of the gate, not a replacement: an absent pow still gets the normal 402, a well-formed pow still faces the real cryptographic verification. `json_schemer` is an OPTIONAL dependency, lazily required only when the flag is on (fail-loud with a clear ConfigurationError if missing); the schema is a vendored self-contained copy of `kiosk.tech/spec/schemas/pow.schema.json` (sync-check tracked as T-045). Slice-1 of the broader uniform-validation layer (T-045).
- **KYC named anonymized attributes.** A KYC attestation MAY now carry an `attributes` object of `{name: true}` booleans (e.g. `age_over_18`, `licence_a`) beside the binary `level`; the verifier records only the granted booleans — never the underlying documents — in the new nullable `agents.kyc_attributes` jsonb column (migration 009, `SchemaDefinitions.kyc_attributes_sql`, install-generator template). `DefaultAgentIdp` gains `kyc_attributes` / `kyc_has_attributes?` so an Action can gate on required attributes, rejecting with the new `kyc_required` (403) error. Additive and backward-compatible: a bare `level: "verified"` attestation still verifies with an empty attribute set.
- **Account binding.** The dormant device-grant machinery is revived as the key-bound claim/link ceremonies: `POST /oauth/device_authorization` requires the agent's `public_key`, the engine-drawn verify page authenticates via `user_idp`, and the token poll demands a possession proof (`signed`, BIND-POP) before any binding — fresh keys register as linked assistant accounts, known keys rebind with reputation carried; link codes mint/redeem via `POST /auth/link` / `POST /auth/claim`; `POST /auth/unlink` deactivates a binding and fires `assistant_unlinked`. Codes are stored hashed in the new durable `DeviceAuthorizationStores::ActiveRecord` default (migration 008); discovery gains `/auth.md` and additive binding keys across the other five surfaces. Tokens remain kiosk-pop-only.
- **Per-assistant spending cap.** A provider MAY cap what each bound assistant may settle, via the `config.spending_cap` pay-hook seam (`(agent_id:) -> cents | nil`, with an optional `spending_cap_window_days` rolling window). The pay path enforces it before the irreversible capture — a cap of 0 disables the assistant — and rejects with the new `spending_cap_exceeded` (403) error. Batteries-included `ColumnSpendingCap` reads the cap from the new nullable `agents.spending_cap_cents` column (plus `human_label`), added idempotently by `SchemaDefinitions.agent_governance_columns_sql`. Opt-in: default off, no behaviour change until wired. Powers per-assistant governance on the manage-assistants page.
- **Manage-assistants governance editing.** The manage-assistants page (`AssistantsController`) gains a `POST …/update` action letting an account holder set each bound assistant's `human_label` and `spending_cap_cents` (blank clears the cap to unlimited; non-integer → 400), ownership-scoped so a holder edits only their own live rows. The listing now also surfaces per-assistant label, settled spend (summed from `settlements`, honouring `spending_cap_window_days`; falls back to zero where no settlements table exists), and the current cap.
- Initial skeleton.
- `Kiosk::Server::ConfigurationExtension` — adds `mount_path`, `capabilities`, `owner`, `min_client` to `Kiosk::Configuration` with lazy defaults.
- `Kiosk::Server::WellKnown` — pure-Ruby builder for `/.well-known/kiosk.json` per spec §3.4. Returns Hash or JSON string. Validates `issuer` is set.
- `/.well-known/api-catalog` discovery document (RFC 9727 standards alignment): a `application/linkset+json` catalog of the live wire endpoints (schema tagged `service-desc`) plus the agents.json companion, so standards-aware agents can discover the Kiosk API surface via the conventional api-catalog URL. Advertised from agents.json under the `x-kiosk` extension.
- `Kiosk::Server::Headers` — composes the three Kiosk response headers (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`).
- `Kiosk::Server::HeadersMiddleware` — Rack middleware that injects the headers on responses whose path starts with the configured mount path.
- `Kiosk::Server::SchemaDefinitions` — pure SQL generators for canonical migrations 001-004 (kiosk schema + current_*() helpers, agents/agent_tokens/agent_mappings, actions/action_log, reservations); typed against the configured user-id type (`:uuid`, `:bigint`, `:integer`, `:text`).
- `Kiosk::Server::Engine` — Rails engine declaration (conditionally loaded when `Rails::Engine` is defined). Auto-mounts `HeadersMiddleware` in the host app's stack.

- **Executor and Errors layer** (follow-up addition within Unreleased):
  - `Kiosk::Server::Errors` hierarchy — `Base`, `BadRequest`, `Unauthenticated`, `Forbidden`, `RLSDenied`, `NotFound`, `QuotaExceeded`, `ActionFailed` — each carrying `CODE` and `HTTP_STATUS` per spec §5.2; `Base#to_envelope` serialises `ok:false` body with `code/message/hint` (nil fields dropped).
  - `Kiosk::Server::Result` Data class — `:rows`/`:value` envelope shapes; `to_envelope` for JSON serialisation.
  - `Kiosk::Server::SessionContext` — opens a transaction on any connection responding to `#transaction`/`#execute`, emits `SET LOCAL` for the four canonical GUCs per spec §6.3; skips `agent_id` GUC for non-agent actors; respects configured `guc_namespace`.
  - `Kiosk::Server::Actions` — minimal process-wide registry (`register(name, &block)`, `fetch(name)`, `known`, `reset!`); raises `Errors::NotFound` on unknown.
  - `Kiosk::Server::Executor` — four-verb dispatch (`query`, `run`, `pay`, `schema`), all fully working against any conforming connection.
  - `Kiosk::Server::WireController` — Rails controller (conditionally defined when `ActionController::API` is loaded); resolves identity via configured `agent_idp` then `user_idp`, parses JSON body, calls `Executor`, serialises envelope with HTTP status + Kiosk headers.

- **Install generator** (follow-up addition within Unreleased):
  - `Kiosk::Generators::InstallGenerator` — `bin/rails g kiosk:install` produces `config/initializers/kiosk.rb` and the four canonical migrations (`create_kiosk_schema`, `create_kiosk_identity_tables`, `create_kiosk_actions_log`, `create_kiosk_reservations`); each migration is a thin wrapper that calls into `Kiosk::Server::SchemaDefinitions` so SQL regenerates against the current `Kiosk.configuration` at `db:migrate` time. Class options: `--user-table`, `--user-id-type`, `--schema`, `--guc-namespace`. Adds `railties ~> 8.1` as a development dependency.

- **Fixes uncovered by the first end-to-end run** (within Unreleased):
  - `SessionContext` now quotes each dot-segment of the GUC name in `SET LOCAL`. Required because `current_role` is a PostgreSQL reserved keyword; unquoted `SET LOCAL app.current_role = '…'` is a syntax error. Quoting is safe across all GUC names.
  - `WireController#parse_body!` now reads `request.raw_post` instead of `request.body.read`. The latter returns empty when a prior middleware (Rails' `ParamsWrapper` with `--api`-style controllers) has already consumed the body stream; `raw_post` is Rails-safe.

- **JWKS foundation** (within Unreleased; first piece of the §6.7 OAuth surface):
  - `Kiosk::Server::SigningKey` — RSA keypair value object. `.generate` for fresh keys, `.from_pem` for loaded keys, `#kid` as the RFC 7638 thumbprint, `#to_jwk` for JWKS-publish shape. Enforces 2048-bit minimum; rejects non-RSA inputs; never leaks private parameters via `#to_jwk`.
  - `Kiosk::Server::Jwks.build(keys: [...])` — pure-Ruby JWKS document builder per RFC 7517. Multi-key shape supports key rotation overlap windows.
  - `Kiosk::Server::ConfigurationExtension#signing_key` — lazy default resolves in this order: explicit setter value, `KIOSK_SIGNING_KEY_PEM` env var, `KIOSK_SIGNING_KEY_B64` env var; raises when none is set (no silent fresh-key generation — a deployment must provide its key). Setter accepts a `SigningKey` instance or a PEM string. `Kiosk.reset!` drops the configured key.

- **JWT issue + verify** (within Unreleased; second piece of the §6.7 OAuth surface):
  - `Kiosk::Server::JwtIssuer.issue(claims:, audience:, ...)` — RS256-signed token with `iat`/`nbf`/`exp`/`iss`/`aud`/`jti` set automatically. JWS header carries `kid` so verifiers can pick the right key during rotation overlap. Default lifetime one hour; caller can override.
  - `Kiosk::Server::JwtIssuer.verify(token:, jwks:, audience:, ...)` — validates signature + lifetime + audience (+ optional issuer) against a JWKS. Returns symbol-keyed claims on success. Raises typed errors: `ExpiredError`, `AudienceError`, `SignatureError`, `InvalidError`.
  - `jwks:` argument accepts a Hash (`{ keys: [...] }`), an Array of `SigningKey`, or a single `SigningKey` — verifier-side ergonomics for the common cases (self-issued, multi-key rotation, single foreign key).
  - Adds `jwt ~> 2.8` dependency (MIT, no transitive deps).

- **JWKS endpoint controller** (within Unreleased; third piece of the §6.7 OAuth surface):
  - `Kiosk::Server::JwksController` — `GET <mount>/.well-known/jwks.json`. Serves `Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key])`. Conditionally defined (only when `ActionController::API` is loaded). Adds Kiosk response headers via `Headers.add_to`.

- **M3 — Install generator extended for migration 005** (within Unreleased):
  - `bin/rails g kiosk:install` now produces five migrations (was four). Added template `create_kiosk_device_authorizations.rb.tt` calling `SchemaDefinitions.device_authorizations_sql` so the host app gets the §6.7 OAuth state-machine table out of the box.
  - Generator spec extended to assert 5-migration count + new `005 create_kiosk_device_authorizations` context (SQL invocation + #down DROP).

- **M3 — `Kiosk::Server::TestExecutor`** (within Unreleased; closes the journey-test infrastructure stream):
  - Pure-Ruby executor satisfying the `Kiosk::TestHelpers::Journey` contract (defined in `kiosk-test-support`). Bridges the rspec/minitest matchers to a real ActiveRecord+Postgres connection so providers can write journey tests against actual RLS policies.
  - `with_identity(identity)` opens an AR transaction, sets the four canonical GUCs via `SessionContext`, yields, **ROLLS BACK unconditionally** — tests stay hermetic across runs. Block return value preserved; exceptions re-raised after rollback. Custom `RollbackMarker` works with both AR (which catches it as a transaction-abort signal) and connection doubles.
  - `query(sql)` enforces default-deny (raises `NoScopeError` outside any `with_identity`), returns rows with symbolised keys, translates Postgres RLS errors (`row-level security`, `violates row-level`, `permission denied for table`) to `Kiosk::TestHelpers::Errors::RLSDenied`.
  - `run_action(name, args)` looks up via `Kiosk::Server::Actions`, calls the registered block with current identity.
  - `pay_action(name, args)` raises `NotImplementedError` (lands with `kiosk-pay-*` in M4).
  - `seed(table, attrs, count:)` bulk-inserts through `system_connection` (RLS-bypass connection the host configures separately); quotes column/table identifiers and values defensively.
  - **Not autoloaded by `require "kiosk/server"`** — test-time infrastructure. Users explicitly `require "kiosk/server/test_executor"` in their `spec_helper.rb` / `test_helper.rb`, then wire `Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new`.
  - Adds `kiosk-test-support` as a development dependency (for error class definitions). Host apps using TestExecutor will have it loaded transitively via `kiosk-rls-rspec` / `kiosk-rls-minitest`.
  - 27 new test examples cover scope enforcement, identity propagation, hermetic rollback semantics, RLS-error translation, action invocation, seed quoting + value rendering. Full kiosk-server suite: 280 examples, 0 failures (was 251 — added 29).

- **Device Authorization Grant — Sub-slices 4+5 of 5: CLI login + e2e wire** (within Unreleased; later unwound):
  - The `kiosk-cli` RFC 8628 login client and the e2e device-login assertions built in this sub-slice were subsequently REMOVED: Kiosk auth is the proof-of-possession challenge-response handshake, not OAuth. `kiosk-cli` is not part of the release, and e2e intentionally does not exercise the device-grant endpoints.
  - The device-grant surface itself (`/oauth/device_authorization`, `/oauth/token`, state machine, stores) stays in kiosk-server as dormant code — retained for a possible future human-in-the-loop consent flow, covered by its unit specs.

- **Device Authorization Grant — Sub-slice 3 of 5: DeviceVerification helper** (within Unreleased; sixth piece of the §6.7 OAuth surface):
  - `Kiosk::Server::DeviceVerification` — pure-Ruby state-machine helpers for the user-facing half of the Device Grant flow. `.find_pending(user_code:)`, `.approve(user_code:, user_id:)`, `.deny(user_code:)`. Strips visual XXXX-XXXX dash + whitespace, upcases (auto-cap keyboards). Raises `CodeNotFoundError` when user_code doesn't resolve to a pending row (distinct from `DeviceAuthorization::StateError` — that one signals a logic error in calling code).
  - **Scope decision:** Kiosk owns the state-machine half (identical across providers). The consent-screen HTML/branding/host-app-login integration is provider responsibility — host's Rails controller calls these helpers from its own actions and renders its own UI. This is consistent with the satellite-mode-neutral principle (Kiosk ships primitives; provider owns presentation).
  - (The e2e `_test/device_authorization` fixture endpoints that exercised this helper were later removed along with the rest of the e2e device-grant wiring — the surface is dormant; coverage lives in the unit specs.)
  - Test coverage: 17 new examples (normalize_user_code 4 / find_pending 6 / approve 5 / deny 2). Full kiosk-server suite: 251 examples, 0 failures (+17).

- **Device Authorization Grant — Sub-slice 2 of 5: OAuth endpoints + e2e wire** (within Unreleased; fifth piece of the §6.7 OAuth surface):
  - `Kiosk::Server::DeviceCodeGrant` — pure-Ruby service module. `.start` and `.exchange` implement the §6.5 + RFC 8628 §3.5 state machine; controllers are thin shims (same pattern as `Executor` ↔ `WireController`). `.exchange` produces a uniform `{ok:, ...}` Hash mapping RFC 8628 error codes (`authorization_pending`, `access_denied`, `expired_token`, `invalid_grant`, `invalid_request`) to outcomes. Lazy expiry: a row past `expires_at` is bumped to `:expired` on first poll, then errors uniformly.
  - `Kiosk::Server::OauthDeviceAuthorizationController` — POST `<mount>/oauth/device_authorization`. Returns the full RFC 8628 §3.2 response (`device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in`, `interval`). Composes `verification_uri` from `request.base_url + mount_path` so it works regardless of where the engine is mounted.
  - `Kiosk::Server::OauthTokenController` — POST `<mount>/oauth/token`. Multi-grant entry point; currently dispatches `urn:ietf:params:oauth:grant-type:device_code` to `DeviceCodeGrant.exchange`. Other grants (`authorization_code` with PKCE, `refresh_token`) return `unsupported_grant_type` with a descriptive note pointing at the follow-up sub-slice.
  - (The e2e device-grant assertions added here were later removed — e2e intentionally does not exercise the dormant surface. The JWT-aware composite IdP (`JwtOrStubIdp`) remains in the e2e fixtures.)
  - Test coverage: 12 new `DeviceCodeGrant` examples covering state-machine outcomes, JWT verification round-trip, expires_in/scope omission. Full kiosk-server suite remains at 234 examples, 0 failures (+12).

- **Device Authorization Grant foundation (RFC 8628) — Sub-slice 1 of 5** (within Unreleased; fourth piece of the §6.7 OAuth surface; covers spec §6.5 `kiosk login` flow):
  - `SchemaDefinitions.device_authorizations_sql` — canonical migration 005. Table `kiosk.device_authorizations` with `device_code_hash bytea`, `user_code text`, `client_id`, `requested_role`, `status` (5-value CHECK constraint), `user_id`, `expires_at`, `consumed_at`, `created_at`. Unique index on `device_code_hash`; partial unique index on `user_code WHERE status='pending'`; expiry-scan index on `expires_at`.
  - `Kiosk::Server::DeviceAuthorization` — `Data`-based value object with the full state machine (`pending → approved | denied → consumed | expired`). Non-destructive transitions via `Data#with`. `.generate(client_id:, requested_role:, expires_in:)` returns `[plain_device_code, da]`; plain code is the only opportunity to read it (persistent form holds only the SHA-256 hash). `user_code` uses 8-char Crockford alphabet (no 0/O/1/I/L/U) for human-friendly typing; `#display_user_code` returns the `XXXX-XXXX` form. `StateError` raised on illegal transitions.
  - `Kiosk::Server::DeviceAuthorizationStores::Base` + `::InMemory` — pluggable storage adapter. InMemory variant is thread-safe via Mutex; suitable for dev / integration tests / small single-process deployments. ActiveRecord adapter follows in a later release.
  - `Kiosk.configuration.device_authorization_store` — lazy-default `InMemory`; setter accepts any subclass of `DeviceAuthorizationStores::Base`. `Kiosk.reset!` drops any configured store.
  - Test coverage: 47 new examples (33 on `DeviceAuthorization` + 14 on stores + config integration). Full kiosk-server suite remains green at 222 examples, 0 failures.

### Out of scope for first release

- OAuth 2.1 surface (authorize/introspect/PKCE/DCR) — dropped as the auth mechanism: Kiosk auth is the proof-of-possession challenge-response handshake; the device-grant code ships dormant.
- Full `Kiosk::Action` DSL (`description`, `accepts`, `requires_payment`, `escalate_to :system`) — current `Actions` registry is a minimal callable map.
- `help` and `events` verbs — removed from the wire surface entirely (`help` dropped by decision, `events` removed too), not deferred.
- `rake kiosk:doctor` — follow-up.
- Full Rails-engine integration tests (requires booting a host app) — follow-up.
- Satellite-mode connection-pool plumbing per spec §7.7 (currently `WireController#connection_for` uses `ActiveRecord::Base.connection`).
