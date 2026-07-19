# Stylish — Kiosk reference demo

Stylish is a hair-styling salon-booking service (stylish.example), Kiosk-enabled. Its one seeded salon is **Combette on Park**. Demonstrates:

- `/.well-known/kiosk.json` discovery
- JWKS endpoint for JWT verification
- Authenticated REST wire surface (`/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema`) — query + run verbs
- App-layer data isolation (two users, two views of the same table); RLS available as optional defense-in-depth
- A `book_appointment` Action
- Human↔assistant account binding over real Devise sessions — the claim ceremony (verify page) and human-minted link codes, walked by `rake demo:binding`
- **Roles from a configured IdP** — stylish is dual-audience: customers book, and salon **staff** (owner / stylist) manage the calendar. A staff member's role, supplied by the provider's own identity system, is inherited by their assistant at link time, and the `salon_calendar` query gates on it (owner sees the whole book + revenue; a stylist only their own chairs). Walked by `rake demo:roles`.

Stylish is the canonical reference shape for personal-services SaaS — barbershops, restaurants, gyms, clinics. Same patterns apply.

> **Auth:** The Kiosk auth story is `kiosk-pop` — register/login by proof-of-possession; `rake demo:register` exercises it end-to-end. The mounted `/kiosk/oauth/*` endpoints are the **account-binding ceremony** (RFC 8628 shape): an assistant's public key gets bound to an existing human account after the human — signed in through the demo's real Devise form — approves on the verify page, and the token poll requires a possession proof for that key. The reverse direction is the human-initiated link code (`/kiosk/auth/link` → `/kiosk/auth/claim`), and `/kiosk/auth/unlink` revokes one assistant without touching the human's own session. Tokens are always minted by kiosk-pop; `/auth.md` describes the methods. `rake demo:binding` walks all of it end-to-end.

## Run the demo

The demo lives in the Kiosk monorepo and resolves its gems by path
(`../kiosk-*` in the Gemfile), so run it from its checked-out directory:

```sh
cd kiosk-demo-stylish
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

### Account binding (`rake demo:binding`)

Two flows, one run, all over plain HTTP against the live app:

1. **First contact (claim)** — an assistant with a fresh key opens the ceremony at `/kiosk/oauth/device_authorization`; the human signs in through the real Devise form (cookie + CSRF dance — no fixtures), approves on the verify page (which shows the key's fingerprint), the assistant's possession-proof poll on `/kiosk/oauth/token` mints a token bound to the human's account, and it books an appointment there.
2. **Human-initiated (link)** — the signed-in human mints a link code, a second assistant redeems it at `/kiosk/auth/claim` and sees the same account's appointments. The human then unlinks the first assistant: its `/kiosk/auth/login` 404s from that moment while the second keeps working.

The task asserts every step, plus the DB ground truth: `kiosk.agents.user_id` for the bound key equals the human's id, and the booking landed on the human's own row.

### Roles from an IdP (`rake demo:roles`)

The role an assistant works with is sourced **indirectly, from the bound human's IdP role** — the natural extension of the link ceremony. A salon owner and a stylist each link an assistant over a role-carrying session (`StubUserIdp`, the salon's SSO/Okta stand-in):

1. **Owner** links an assistant → the token carries `role: owner` → `salon_calendar` returns the **whole book** (every stylist's appointments) plus a revenue total.
2. **Stylist** links an assistant → the token carries `role: stylist` → `salon_calendar` returns **only that stylist's own chairs**.

The role rides the token, sourced from the provider's identity system — never self-selected by the agent. A stylist's assistant cannot widen its scope to the owner's book: the role is set at binding from the IdP (not the claim body), and the query's `WHERE` is provider-controlled. `rake demo:roles` asserts both views with DB ground-truth on `kiosk.agents.allowed_roles`, and the redteam battery (`rake demo:redteam`) proves the escalation is BLOCKED.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | Generator-produced kiosk migrations + the Stylish salon/appointment schema (users carry Devise login columns + a `staff_role`; appointments carry a `stylist_id`) |
| `app/models/{user,salon,appointment}.rb` | Three trivial AR models; `User` is `database_authenticatable` for the human sign-in and carries `staff_role` (owner/stylist) for the staff surface |
| `config/initializers/kiosk.rb` | `Kiosk.configure` block + the `book_appointment` Action + the role-gated `salon_calendar` query |
| `config/initializers/devise.rb` | Minimal Devise setup — the human session that approves assistant links |
| `lib/stub_idp.rb` | Bespoke synthetic-token agent-IdP for the demo's hard-coded Alice + Bob |
| `lib/jwt_or_stub_idp.rb` | Composite agent-IdP: tries Kiosk-issued JWTs first, falls back to StubIdp |
| `lib/stub_user_idp.rb` | Role-carrying **user**-IdP (SSO/Okta stand-in): an `X-Staff-Session` header names a staff member; the session identity carries their `staff_role` |
| `lib/composite_user_idp.rb` | Composite user-IdP: the role-carrying StubUserIdp first, then the real Devise session |
| `binding_flow.rb` | Account-binding driver: claim ceremony over the real Devise session, link-code redeem, unlink |
| `roles_flow.rb` | roles-from-IdP driver: owner + stylist each link an assistant, `salon_calendar` gates on the inherited role |
| `bin/demo` | The walkthrough — POSIX shell, curl-driven, no Ruby in the loop |
| `lib/tasks/demo.rake` | `rake demo:setup`, `rake demo:walkthrough`, `rake demo`, `rake demo:isolation`, `rake demo:register`, `rake demo:binding`, `rake demo:roles`, `rake demo:redteam`, `rake demo:schema` |

## Make it real

The demo bakes in shortcuts that production providers replace. Each transition is small:

- **Synthetic users (Alice, Bob) + staff (owner, stylists)** → real user table populated by your provider's signup flow (the demo already gives them real Devise credentials so the binding walkthrough signs in like a person would).
- **`StubIdp`** (agent channel) → registered assistants already flow through real Kiosk-issued JWTs; the bespoke `agent:u-…:a-…:r-…` fallback shape disappears. The human session channel already runs the real `kiosk-user-idp-devise` adapter.
- **`StubUserIdp`** (the role-carrying SSO/Okta stand-in) → your real SSO/OIDC session. The Devise adapter already reads a per-user role via `User#kiosk_role`, so a production provider drops the stub and sources the staff role from its own identity system; the assistant inherits it at link time unchanged.

## License

Apache-2.0.
