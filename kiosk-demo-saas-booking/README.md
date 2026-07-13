# Combette — Kiosk reference demo

A salon-booking SaaS, Kiosk-enabled. Demonstrates:

- `/.well-known/kiosk.json` discovery
- JWKS endpoint for JWT verification
- Authenticated REST wire surface (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema`) — query + run verbs
- App-layer data isolation (two users, two views of the same table); RLS available as optional defense-in-depth
- A `book_appointment` Action

Combette is the canonical reference shape for personal-services SaaS — barbershops, restaurants, gyms, clinics. Same patterns apply.

> **Auth:** The Kiosk auth story is `kiosk-pop` — register/login by proof-of-possession (ADR-0008); `rake demo:register` exercises it end-to-end. The OAuth 2.1 device-grant code ships in kiosk-server but stays dormant: its `/kiosk/oauth/*` endpoints are mounted here for wire-shape parity with the other demos, and this demo provides no consent UI, so the flow cannot complete. Linking an agent to an existing human account is a post-0.1 feature.

## Run the demo

```sh
git clone https://github.com/kiosk-hq/kiosk-demo-saas-booking.git
cd kiosk-demo-saas-booking
bundle install
rake demo
```

`rake demo` creates the Postgres database, runs migrations + seeds, boots the Rails server, and walks through discovery, named queries, the `book_appointment` Action, and Alice/Bob isolation with `curl` + `jq` output. (`/kiosk/schema` and `/kiosk/pay` are not part of this walkthrough — see `rake demo:schema` and the e2e harness.)

### Prerequisites

- Ruby 4.0+, Postgres reachable (`pg_isready` returns OK)
- `curl`, `jq` on PATH

## What the demo shows

The walkthrough (`bin/demo`) prints four sections:

1. **Discovery** — well-known + JWKS payloads, so an agent host like claude.ai sees what's behind the URL
2. **Named query** — `POST /kiosk/query` with `{name: ...}`, returning rows scoped by app-layer authz
3. **Run an Action** — `POST /kiosk/run` invoking `book_appointment` (the demo's lone registered Action)
4. **Isolation** — same query run as Alice vs Bob; each sees only their own (enforced in the query block, RLS optional)

After the walkthrough finishes, the server is torn down cleanly. Server logs are at `/tmp/kiosk-demo.log` if you want to inspect what hit the HTTP surface.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | Generator-produced kiosk migrations + the Combette schema |
| `app/models/{user,salon,appointment}.rb` | Three trivial AR models |
| `config/initializers/kiosk.rb` | `Kiosk.configure` block + the `book_appointment` Action |
| `lib/stub_idp.rb` | Bespoke synthetic-token IdP for the demo's hard-coded Alice + Bob |
| `lib/jwt_or_stub_idp.rb` | Composite IdP: tries Kiosk-issued JWTs first, falls back to StubIdp |
| `bin/demo` | The walkthrough — POSIX shell, curl-driven, no Ruby in the loop |
| `lib/tasks/demo.rake` | `rake demo:setup`, `rake demo:walkthrough`, `rake demo`, `rake demo:isolation`, `rake demo:register`, `rake demo:redteam`, `rake demo:schema` |

## Make it real

The demo bakes in shortcuts that production providers replace. Each transition is small:

- **Synthetic users (Alice, Bob)** → real user table populated by your provider's signup flow.
- **`StubIdp`** → `kiosk-user-idp-devise` (or your IdP adapter). The bespoke `agent:u-…:a-…:r-…` token shape disappears; real Kiosk-issued JWTs flow through.

## License

Apache-2.0.
