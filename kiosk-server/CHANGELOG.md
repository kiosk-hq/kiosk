# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **The `/auth.md` every operator serves stopped teaching an error contract the wire retired (T-068 slice 7).** Its Errors section described the 0.3 `{ ok: false, error: { code, message, hint } }` envelope; since 0.4 every refusal — the auth plane included — is an RFC 9457 problem document with the code as a flat member. An assistant that believed the document was branching on a field that no longer exists, so the section now shows the document it will actually receive, and a spec pins the shape rather than the prose.

- **`GET <endpoint>/openapi.json` is PUBLIC too, and `POLICY_VERBS` is gone with the toll it existed for (K-804).** The derived OpenAPI document renders the same registry `GET <endpoint>/schema` renders, so gating one while the other is open withheld nothing; it now takes the identical treatment — no Bearer, no toll, `public` with a strong `ETag`, a `304`, and a year at `?v=<version>` — from one shared render seam, so the two cannot drift apart again. `Executor::POLICY_VERBS` had become a byte-identical copy of `VERBS` under a second name and was deleted rather than kept as documentation.

- **The public documents expire in a minute and carry no `Vary` at all.** `Headers::SHORT_MAX_AGE` drops from 300 to 60 — the number is how long a deploy takes to become visible to a client holding the previous pointer, not a cache-efficiency knob, since the traffic is absorbed by the immutable `?v=` url — and `DiscoveryController` drops the `Vary: Accept` Rails stamps on any negotiated render, which would otherwise split a shared cache by `Accept` string for a variance none of these six documents has. `/.well-known/api-catalog` also links both service descriptions at their versioned url rather than at the bare path.

- **`GET <endpoint>/schema` is PUBLIC, cacheable, and no longer tolled (T-094).** The verb catalogue holds no per-agent value and no secret, so gating it while `/.well-known/*` stood open bought nothing and cost an explanation; it is now served from a document derived once at boot by the engine, under `public` caching with a strong `ETag`, and the discovery documents link it at `?v=<digest>` so a deploy invalidates every cache by changing the URL rather than by hoping a TTL expires. `/kiosk/openapi.json` is deliberately left gated.

- **`/.well-known/api-catalog` hyperlinks every verb the origin serves, unauthenticated (T-093).** The RFC 9727 linkset used to name one endpoint per module because the verb roster was treated as something to withhold; it is not a secret, and a document composed from in-process state caches behind a CDN, so the catalog now lists the real per-verb endpoints with the method each one answers, alongside the two service descriptions it already carried.

- **The `schema` descriptor drops `verbs` and the module set has ONE home (T-095).** `verbs` rendered the very call `/.well-known/kiosk.json` renders as `capabilities`, so it was one value published twice under two names rather than two facts; `capabilities` is the single spelling, and a client reads it from the discovery document it already fetches first.

### Fixed

- **A provider that configures no `registration_role` can register assistants again (K-788).** Roles are optional by decision (ADR-0011: "registration MUST NOT fail when it is unset"), but the register door and the fresh-key binding branch wrote a literal `NULL` into `agents.allowed_roles`, which the shipped migration declares `NOT NULL` — so both 500'd for exactly the single-role operator the decision protects, while every shipped demo configures a role and never saw it. "No role" is now the empty role set.

### Security

- **The identity GUCs are set through bind parameters (K-789).** `SessionContext` built `SET LOCAL <name> = '<value>'` with a hand-rolled quote-doubler — the last value escaped by hand anywhere in the gem, and the one value every predicate and every RLS policy trusts. Postgres takes no binds in `SET`, so the statement is now `SELECT set_config($1, $2, true)`, whose third argument IS `LOCAL`; equivalence (same value in the transaction, gone after COMMIT and after ROLLBACK) is asserted against a real database rather than argued. `SessionContext`'s connection contract moves from `#execute` to `#exec_query`, and `#guc_statements` returns `[sql, binds]` pairs.

- **The pay path writes through bind parameters, not assembled SQL (K-654).** `Executor`'s four `persist_*` helpers and its spending-cap tally were heredocs with every value spliced in through a private `connection.quote` wrapper; they now pass `$1…$N` binds to `exec_query`, so a value can no longer be read as SQL and there is no quote call left to omit. Nothing on the wire changes — this closes the gap between what the engine ships and what it asks operators to do, since the same idiom was removed from all seven demos first. `WireController` also stops calling the Rails-8.1 soft-deprecated `ActiveRecord::Base.connection`, which raises outright under `permanent_connection_checkout = :disallowed`.

### Removed

- **`Kiosk::Server::Queries.register` / `Kiosk::Server::Actions.register` are gone (T-081).** A shipped public API of the 0.3 series is removed with no deprecation shim: an initializer that calls one now raises NoMethodError. A verb is declared one way — a controller that `include`s `Kiosk::Query` / `Kiosk::Action`, named in `c.handlers` — because the second shape could not be reloaded, could not be reached by the host's filters, `rescue_from` or strong parameters, and taught, in the file an adopter copies first, that Rails does not apply to the surface they expose to assistants. The registries' read surface (`fetch`, `describe`, `catalog`, `known`) is unchanged and the wire is byte-identical, including the ADR-0023-retired `params` descriptor slot, which no macro can set and which keeps publishing null.

### Added

- **The install generator now emits the `c.handlers` slot.** `rails generate kiosk:install` previously produced an initializer that never mentioned `c.handlers`, so a fresh operator following the generator — rather than the onboarding page — landed in exactly the dead-origin state that hole causes (empty schema catalog, 404 on `query`/`run`, `"capabilities": []`). The template now emits an active `c.handlers = []` (empty because no handler controllers exist yet at generation time — naming one would fail boot) with a comment stating the consequence of leaving it empty and the fill-in syntax for when handlers exist.

- **The engine owns handler registration.** An operator names their handler controllers (`c.handlers = %w[Kiosk::CatalogController]`) and the engine registers them — at boot in every environment, and again after every code reload — so a mixin-declared verb is on the wire in development, where nothing eager-loads `app/` and nothing else ever references a handler controller. Without it such an origin served no verbs at all: an empty schema catalog, a 404 on every `query`/`run`, and discovery advertising `"capabilities": []`. Each pass rebuilds rather than re-registers, so a verb deleted from a controller also leaves the wire; registrations made through the `Queries.register` initializer API are untouched.

- **The engine owns the routes.** `mount Kiosk::Server::Engine => Kiosk.configuration.mount_path` is now the whole routing story: the engine's drawer carries the wire verbs, the kiosk-pop auth plane, JWKS, KYC attestation and the account-binding ceremony (including the previously missing `auth/assistants/update` the page's own form posts to), and a mount-gated `routes.append` initializer installs the root-relative discovery documents (`/agents.txt`, `/agents.json`, `/auth.md`, `/.well-known/*`) into the host app. Merely bundling the gem stays inert — no mount, no routes — and hand-drawn routes keep winning over the engine's (Rails dispatches the first match), so hand-mounted hosts are unchanged and hand-drawing remains the documented escape hatch.

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

### Changed

- **Discovery advertises MODULES, and the catalog's `verbs` IS `capabilities`
  (T-068 slice 5; T-075 = A, K-740, ADR-0025).** `Kiosk.configuration
  .capabilities` — and therefore `/.well-known/kiosk.json` — now computes
  `["schema", "queries", "actions", "pay"]` from the same three questions of
  the same registry it always asked; only the names it emits moved from verbs
  to modules. `Executor#verb_schema` stops emitting the `VERBS` constant and
  answers with that same array, so an origin with no payment provider no
  longer advertises `pay` in one self-description and omits it from the other.
  `agents.json`'s `x-kiosk` block stops echoing the capability list: it is now
  `{schema, api_catalog, mount_path, api_version}` — pointers, not a copy of
  the contract — and `min_client` went with the echo (`kiosk.json` is
  canonical for it). `/.well-known/api-catalog` maps one link per module.
  Intent: none of these documents requires a token, and the verb list is
  deliberately behind one — `GET <endpoint>/schema` and
  `GET <endpoint>/openapi.json` both demand Bearer, and the per-verb wire
  answers `401` before `404` so an anonymous prober cannot enumerate names.
  BREAKING for anything that read the old spellings: the member values change,
  the field names do not.

- **The error taxonomy is the wire contract, not a parallel class hierarchy.**
  The `error.code` vocabulary now lives in one table, and handlers express
  errors in Rails' own idiom: a rendered status becomes its wire code, an
  exception registered in `config.action_dispatch.rescue_responses` is mapped
  by a single `rescue_from` the mixin installs (the operator's own handlers
  win over it), and an explicitly rendered vocabulary code — including a
  specific 402 — travels verbatim. Intent: an operator should never need a
  Kiosk exception class to say what a bare `render json:, status:` already
  says; the classes that restated HTTP statuses are deprecated for handler
  code, and the unused `QuotaExceeded` class is gone (the code stays
  reserved in the vocabulary).

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
