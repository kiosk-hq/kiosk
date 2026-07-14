# Kiosk OSS — end-to-end test

Reproducible end-to-end test of the Kiosk OSS gems. The same script (`run.sh`) runs locally and in CI.

## What it verifies

- The `kiosk:install` Rails generator produces working migrations
- `kiosk-server` Rails engine boots inside a fresh app
- `/.well-known/kiosk.json` discovery endpoint returns a valid document
- Response headers (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`) are injected on `/kiosk/*`
- `POST /kiosk/{query,run,pay}` accept JSON requests and dispatch through `Kiosk::Server::Executor`
- The `query` verb calls provider-registered named queries (`salons`, `my_appointments`) and returns rows
- The `run` verb dispatches to registered Actions
- Error envelopes have the right shape and HTTP status (`NotFound` → 404 for unknown query/action, `Unauthenticated` → 401 for missing/garbage token)
- The `/kiosk/.well-known/jwks.json` endpoint publishes exactly one RSA/RS256 signing key (kty/use/alg/kid/n/e) and never leaks private parameters (`d`, `p`)
- The partial UNIQUE index on `kiosk.agents.public_key` (WHERE `revoked_at IS NULL`) rejects a second LIVE row for one key at the DB level while allowing a revoked re-registration (K-043)
- `SET LOCAL` GUCs flow correctly: the `book_appointment` Action reads `kiosk.current_user_id()` and the `my_appointments` query returns only the calling principal's rows (app-layer isolation via `WHERE user_id = kiosk.current_user_id()`)
- The `pay` verb settles a full AP2 mandate trail: `pay_flow.rb` self-registers a synthetic principal, signs intent → cart → payment mandates (JWS), pays against a stub PSP; assertions cover the response envelope and all four DB tables (`intent_mandates`, `cart_mandates`, `payment_mandates`, `settlements`)

## What it does NOT verify (deferred)

- **RLS.** Path C removes raw SQL entirely — there is no arbitrary-SQL surface. Per-user isolation is enforced app-layer in registered query definitions (the `WHERE user_id = kiosk.current_user_id()` in `my_appointments`). RLS is optional and its enforcement is not exercised in this fixture; satellite-mode role separation lands in a follow-up. The `app_role` pre-creation in `run.sh` is kept harmless for forward compatibility. Note: the `kiosk-rls` gem is still installed (see `run.sh`), because it is the only source of `Configuration#system_role=`, which `initializer_kiosk.rb` assigns — the gem is a mandatory boot dependency here even though RLS itself is off.
- **Live PSP capture.** The pay flow runs against `StubPsp` (deterministic in-process provider) — no real Stripe call here; the Stripe adapter is `kiosk-pay-stripe`.
- **Streaming.** There is no streaming/events verb (removed K-083); the wire surface is `query`, `run`, `pay`, `schema`.
- **Multi-agent revocation** flows.
- **Live LLM agent integration** — this fixture drives the wire surface with deterministic `curl`/`jq` calls, not a real model; a live-LLM driver would be a future companion gem (`kiosk-agent-test` does not exist yet).

## Prerequisites

- **Ruby 4.0+** with Bundler
- **PostgreSQL** reachable (default: `localhost` with the running user as superuser; e.g. `brew services start postgresql`)
- **`rails` gem** — the script installs it automatically if missing
- **`curl`** and **`jq`** on the PATH

## Run locally

```bash
cd /path/to/kiosk-hq/kiosk        # or your local oss clone
./e2e/run.sh
```

The script:

1. Creates a temp dir + fresh Rails app via `rails new -d postgresql --skip-test --api`
2. Patches the Gemfile to point at sibling kiosk gem paths
3. `bundle install`
4. Stages the `User` model migration (UUID PK)
5. Runs `bin/rails g kiosk:install --user-id-type=uuid` (the kiosk-server generator)
6. Stages the demo migration (`salons` + `appointments`; RLS not used — app-layer isolation via named queries)
7. Stages models, seeds, stub IdP, initializer, routes
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
├── README.md                               # this file
└── fixtures/                               # files copied into the generated app
    ├── create_users.rb                     # provider's user table (UUID PK)
    ├── create_salons_and_appointments.rb   # demo schema (salons + appointments)
    ├── user.rb, salon.rb, appointment.rb   # ActiveRecord models
    ├── seeds.rb                            # 2 users (Alice + Bob), 1 salon
    ├── stub_idp.rb                         # Bearer-token-parsing agent IdP
    ├── jwt_or_stub_idp.rb                  # composite IdP: Kiosk-issued JWTs + StubIdp fallback
    ├── stub_psp.rb                         # deterministic in-process PSP (no real Stripe)
    ├── pay_flow.rb                         # no-human AP2 pay flow: register → sign mandates → pay
    ├── initializer_kiosk.rb                # Kiosk.configure + registered Action
    └── routes.rb                           # mounts /kiosk/{query,run,pay,schema} + /.well-known/kiosk.json
```
