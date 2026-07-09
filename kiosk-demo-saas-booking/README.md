# Combette — Kiosk reference demo

A salon-booking SaaS, Kiosk-enabled. Demonstrates:

- `/.well-known/kiosk.json` discovery
- JWKS endpoint for JWT verification
- Authenticated REST wire surface (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema`) — query + run verbs
- App-layer data isolation (two users, two views of the same table); RLS available as optional defense-in-depth
- OAuth 2.1 Device Authorization Grant (RFC 8628) — the agent-login flow
- A `book_appointment` Action

Combette is the canonical reference shape for personal-services SaaS — barbershops, restaurants, gyms, clinics. Same patterns apply.

## Run the demo

```sh
git clone https://github.com/kiosk-hq/kiosk-demo-saas-booking.git
cd kiosk-demo-saas-booking
bundle install
rake demo
```

`rake demo` creates the Postgres database, runs migrations + seeds, boots the Rails server, and walks through every wire endpoint with `curl` + `jq` output. Takes ~30 seconds end-to-end.

### Prerequisites

- Ruby 4.0+, Postgres reachable (`pg_isready` returns OK)
- `curl`, `jq` on PATH

## What the demo shows

The walkthrough (`bin/demo`) prints six sections:

1. **Discovery** — well-known + JWKS payloads, so an agent host like claude.ai sees what's behind the URL
2. **Named query** — `POST /kiosk/query` with `{name: ...}`, returning rows scoped by app-layer authz
3. **Run an Action** — `POST /kiosk/run` invoking `book_appointment` (the demo's lone registered Action)
4. **Isolation** — same query run as Alice vs Bob; each sees only their own (enforced in the query block, RLS optional)
5. **OAuth Device Grant** — full flow: device_authorization → user approval (simulated) → token poll → JWT bearer
6. **JWT against `/kiosk/query`** — the OAuth-issued bearer is interchangeable with the legacy synthetic shape

After the walkthrough finishes, the server is torn down cleanly. Server logs are at `/tmp/kiosk-demo.log` if you want to inspect what hit the HTTP surface.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | Generator-produced kiosk migrations + the Combette schema |
| `app/models/{user,salon,appointment}.rb` | Three trivial AR models |
| `config/initializers/kiosk.rb` | `Kiosk.configure` block + the `book_appointment` Action |
| `lib/stub_idp.rb` | Bespoke synthetic-token IdP for the demo's hard-coded Alice + Bob |
| `lib/jwt_or_stub_idp.rb` | Composite IdP: tries OAuth-issued JWTs first, falls back to StubIdp |
| `bin/demo` | The walkthrough — POSIX shell, curl-driven, no Ruby in the loop |
| `lib/tasks/demo.rake` | `rake demo:setup`, `rake demo:walkthrough`, `rake demo` |

## Make it real

The demo bakes in shortcuts that production providers replace. Each transition is small:

- **Synthetic users (Alice, Bob)** → real user table populated by your provider's signup flow.
- **`StubIdp`** → `kiosk-user-idp-devise` (or your IdP adapter). The bespoke `agent:u-…:a-…:r-…` token shape disappears; real OAuth bearers flow through.
- **In-memory `DeviceAuthorizationStore`** → `ActiveRecord::Base`-backed store using migration 005's `kiosk.device_authorizations` table.
- **`/_test/device_authorization/verify` fixture endpoint** → your provider's branded `/oauth/device/verify` consent page, calling `Kiosk::Server::DeviceVerification.{approve,deny}` after Devise authenticates `current_user`.

## License

Apache-2.0.
