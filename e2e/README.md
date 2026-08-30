# Kiosk OSS — end-to-end test

Reproducible end-to-end test of the Kiosk OSS gems. The same script (`run.sh`) runs locally and in CI.

## What it verifies

- The `kiosk:install` Rails generator produces working migrations
- `kiosk-server` Rails engine boots inside a fresh app
- `/.well-known/kiosk.json` discovery endpoint returns a valid document
- Response headers (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`) are injected on `/kiosk/*`
- The 0.4 per-verb endpoints (`GET /kiosk/<query-name>`, `POST /kiosk/<action-name>`) and `POST /kiosk/pay` dispatch through `Kiosk::Server::Executor` — a query's arguments ride in the query string, an action's in the JSON body
- `GET /kiosk/salons` and `GET /kiosk/my_appointments` reach the origin's named queries and answer a bare JSON array of rows (no envelope), with `X-Total-Count` beside it and NO `Link` header, because the fixture's one-salon dataset is a complete page. That a page's cursor rides in an RFC 8288 `Link` header is asserted only as an OpenAPI DECLARATION here; a truncated page with a live cursor is exercised by the demos (hoteling `demo:search`), not by this fixture
- `POST /kiosk/book_appointment` reaches the origin's named Action and answers that handler's own JSON object
- Handler controllers declared with `include Kiosk::Handler` and named in `c.handlers` are registered and served in DEVELOPMENT, where nothing eager-loads `app/` (K-761)
- ONE controller serves BOTH kinds: `Kiosk::BookingsController` declares `my_appointments` (`kind :query`, reached by `GET`) and `book_appointment` (`kind :action`, reached by `POST`), and both answer over the wire (K-921)
- Errors are RFC 9457 problem documents — `application/problem+json`, `type`/`title`/`status`/`code`/`hint`, the branch point a FLAT top-level `code` — with the right HTTP status (unknown verb name → 404 `not_found`, missing/garbage token → 401 `unauthenticated`)
- The `/kiosk/.well-known/jwks.json` endpoint publishes exactly one RSA/RS256 signing key (kty/use/alg/kid/n/e) and never leaks private parameters (`d`, `p`)
- The partial UNIQUE index on `kiosk.agents.public_key` (WHERE `revoked_at IS NULL`) rejects a second LIVE row for one key at the DB level while allowing a revoked re-registration
- `SET LOCAL` GUCs flow correctly: the `book_appointment` Action reads `kiosk.current_user_id()` and the `my_appointments` query returns only the calling principal's rows (app-layer isolation via `WHERE user_id = kiosk.current_user_id()`)
- The `pay` verb settles a full AP2 mandate trail: `pay_flow.rb` self-registers a synthetic principal, signs intent → cart → payment mandates (JWS), pays against a stub PSP; assertions cover the unenveloped `pay` response body and all four DB tables (`intent_mandates`, `cart_mandates`, `payment_mandates`, `settlements`)

## What it does NOT verify (deferred)

- **RLS.** Path C removes raw SQL entirely — there is no arbitrary-SQL surface. Per-user isolation is enforced app-layer in the handler controllers (the `WHERE user_id = kiosk.current_user_id()` in `my_appointments`). RLS is optional and its enforcement is not exercised in this fixture; satellite-mode role separation lands in a follow-up. The `app_role` pre-creation in `run.sh` is kept harmless for forward compatibility. Note: the `kiosk-rls` gem is still installed (see `run.sh`), because it is the only source of `Configuration#system_role=`, which `initializer_kiosk.rb` assigns — the gem is a mandatory boot dependency here even though RLS itself is off.
- **Live PSP capture.** The pay flow runs against `StubPsp` (deterministic in-process provider) — no real Stripe call here; the Stripe adapter is `kiosk-pay-stripe`.
- **Streaming.** There is no streaming/events verb; the wire surface is one endpoint per registered verb, plus `pay` and the public `schema` / `openapi.json` catalogue.
- **Multi-agent revocation** flows.
- **Live LLM agent integration** — this fixture drives the wire surface with deterministic `curl`/`jq` calls, not a real model; a live-LLM driver would be a future companion gem (`kiosk-agent-test` does not exist yet).

## Prerequisites

- **Ruby 4.0+** with Bundler
- **PostgreSQL** reachable (default: `localhost` with the running user as superuser; e.g. `brew services start postgresql`)
- **`rails` gem** — the script installs it automatically if missing
- **`curl`** and **`jq`** on the PATH

## Run locally

```bash
cd /path/to/kiosk-hq/kiosk        # or your local clone
./e2e/run.sh
```

The script:

1. Creates a temp dir + fresh Rails app via `rails new -d postgresql --skip-test --api`
2. Patches the Gemfile to point at sibling kiosk gem paths
3. `bundle install`
4. Stages the `User` model migration (UUID PK)
5. Runs `bin/rails g kiosk:install --user-id-type=uuid` (the kiosk-server generator)
6. Stages the demo migration (`salons` + `appointments`; RLS not used — app-layer isolation via named queries)
7. Stages models, handler controllers, seeds, app services, initializer, routes (no agent IdP — the engine's own `DefaultAgentIdp` authenticates assistants, with nothing configured)
8. `rails db:create db:migrate db:seed`
9. Starts `rails s` on port 3001 in the background
10. Runs `assistant.sh` — a series of `curl + jq` calls that assert on the responses
11. Tears down (kills server, drops DB, removes temp dir)

Output is colour-coded `✓` / `✗` per assertion; exits non-zero on any failure.

## Configure

| Env var | Default | What it does |
|---|---|---|
| `KIOSK_OSS` | auto-detected from script path | Path to the reference monorepo root (sibling-gem path overrides resolve from here) |
| `PGHOST` | `localhost` | Postgres host for the generated `database.yml` |
| `SERVER_PORT` | `3001` | Port for the in-test Rails server |

## CI

`.github/workflows/ci.yml` invokes the same script (the `e2e` job) after standard Ruby + Postgres setup. The CI service-postgres user is a superuser, same as a typical local Homebrew setup — no role-separation differences.

## File layout

```
e2e/
├── run.sh                                  # main script
├── assistant.sh                            # the mock AI assistant
├── schema_conformance.rb                   # the published JSON Schemas run against THIS origin's live wire bytes (K-822), §5/§6 included (T-152)
├── schemas/                                # vendored copies of seven of the eight published normative schemas (pow.schema.json is vendored in kiosk-server instead; `bin/check-spec-schemas` holds all eight against the originals)
├── mise.toml                               # pins the Ruby the harness runs on
├── README.md                               # this file
└── fixtures/                               # files copied into the generated app
    ├── create_users.rb                     # provider's user table (UUID PK)
    ├── add_devise_columns_to_users.rb      # the human-login columns on that table (email + encrypted_password)
    ├── create_salons_and_appointments.rb   # demo schema (salons + appointments)
    ├── application_controller.rb           # ActionController::Base (not ::API) — Devise's controllers inherit it and need `flash`
    ├── user.rb, salon.rb, appointment.rb   # ActiveRecord models
    ├── seeds.rb                            # 2 users (Alice + Bob) with Devise credentials, 1 salon
    ├── bind_assistants.rb                  # mints the suite's two agent principals by ceremony: register → the human's link code → claim (no agent IdP is staged — the engine's own DefaultAgentIdp verifies the tokens it mints)
    ├── stub_psp.rb                         # deterministic in-process PSP (no real Stripe)
    ├── demo_audit_sink.rb                  # the OPERATOR's `c.audit_sink` callable — Kiosk stores no audit trail (K-828), so the harness writes the one an adopter would
    ├── equihash_register.rb                # shared register helper: challenge → PoP → register; solves the register 402 + retries with the Kiosk-PoW header
    ├── register_pow_flow.rb                # register-PoW driver: no-proof register → 402, solve + re-POST with Kiosk-PoW header → 201, token authenticates a verb
    ├── pay_flow.rb                         # no-human AP2 pay flow: register → sign mandates → pay
    ├── auth_wire_capture.rb                 # the §5/§6 ceremonies driven for their BYTES: kiosk-pop (challenge → tolled register → login → revoke), link → claim → unlink, and the device grant with a real verify-page approval — written to AUTH_CAPTURE for schema_conformance.rb (T-152)
    ├── claim_flow.rb                       # account-binding claim ceremony: fresh key → verify-page approval → PoP token → bound wire call → link-code redeem → unlink
    ├── catalog_controller.rb               # Kiosk::CatalogController — `include Kiosk::Handler`, `kind :query`: the salons verb
    ├── bookings_controller.rb              # Kiosk::BookingsController — `include Kiosk::Handler`: the my_appointments QUERY and the book_appointment ACTION in ONE controller (K-921)
    ├── devise_initializer.rb               # Devise setup (database_authenticatable) — the HUMAN channel the binding pages authenticate
    ├── initializer_kiosk.rb                # Kiosk.configure, including `c.handlers` naming the two controllers above
    ├── environment_kiosk.rb                 # SPLICED (not copied) into the generated config/environments/{development,production}.rb, ahead of their closing `end`: the block that resolves the harness's four env inputs and publishes them as `Rails.configuration.x.kiosk.*`, which the initializer above then READS (ENV-CONFIG-PLACEMENT, K-1009). Both files get the same block so KIOSK_POW_SECRET still fails loud outside development
    └── routes.rb                           # hand-draws /kiosk/schema, /kiosk/pay, /kiosk/openapi.json, /kiosk/auth/{challenge,register,login,revoke,link,claim,unlink}, jwks, oauth/* device + verify routes, the root discovery documents (/agents.{txt,json}, /auth.md, /.well-known/{agent-configuration,kiosk.json,api-catalog}) and — LAST, so every reserved line above wins — the per-verb `GET|POST /kiosk/:kiosk_verb` pair
```
