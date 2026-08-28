# Stylish — Kiosk reference demo

Stylish is a hair-styling salon-booking service (stylish.example), Kiosk-enabled. Its one seeded salon is **Combette on Park**. Demonstrates:

- `/.well-known/kiosk.json` discovery
- JWKS endpoint for JWT verification
- Authenticated REST wire surface — **one endpoint per verb**: a query is a `GET /kiosk/<query-name>` with its arguments in the query string, an action is a `POST /kiosk/<action-name>` with its arguments as the JSON body, and the success body IS the result (no envelope). `GET /kiosk/schema`, `GET /kiosk/openapi.json` and `POST /kiosk/pay` keep their own paths; errors are RFC 9457 problem documents whose top-level `code` is what an assistant branches on
- App-layer data isolation (two users, two views of the same table); RLS available as optional defense-in-depth
- A `book_appointment` Action + an `availability`/`service_menu` query — an **evergreen service menu**: a small set of services, each with a EUR price, all always bookable (infinite capacity, overbooking allowed — the salon never fills up, so the demo never goes empty or stale and needs no reseed cron). The salon starts with zero bookings; real bookings accumulate as visitors book.
- Human↔assistant account binding over real Devise sessions — the claim ceremony (verify page) and human-minted link codes, walked by `rake demo:binding`
- **Roles from a configured IdP** — stylish has two entrances: a **visitor** books a service off the menu, and the salon **owner** views the forecast. The owner's role, supplied by the operator's own identity system, is inherited by their assistant at link time, and the `salon_calendar` query gates on it (owner sees every booking + a *forecasted* € revenue — summed live from the actual bookings' prices, starting at €0 and growing as visitors book; a visitor sees only their own bookings and no forecast). Walked by `rake demo:roles`. (Multi-account is deferred, so a tester acts as a visitor **or** as the owner, not both at once.)

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

1. **Discovery** — well-known + JWKS payloads, so an AI-assistant host like claude.ai sees what's behind the URL
2. **A query** — `GET /kiosk/salons` and `GET /kiosk/availability`, each answering a bare JSON array scoped by app-layer authz
3. **An Action** — `POST /kiosk/book_appointment` (the demo's lone registered Action), arguments in the JSON body, answering the booking object itself
4. **Isolation** — same query run as Alice vs Bob; each sees only their own (enforced in the query block, RLS optional)

After the walkthrough finishes, the server is torn down cleanly. Server logs are at `/tmp/kiosk-demo.log` if you want to inspect what hit the HTTP surface.

### Account binding (`rake demo:binding`)

Two flows, one run, all over plain HTTP against the live app:

1. **First contact (claim)** — an assistant with a fresh key opens the ceremony at `/kiosk/oauth/device_authorization`; the human signs in through the real Devise form (cookie + CSRF dance — no fixtures), approves on the verify page (which shows the key's fingerprint, when it asked, and the access the approval hands over), the assistant's possession-proof poll on `/kiosk/oauth/token` mints a token bound to the human's account, and it books an appointment there.
2. **Human-initiated (link)** — the signed-in human mints a link code, a second assistant redeems it at `/kiosk/auth/claim` and sees the same account's appointments. The human then unlinks the first assistant: its `/kiosk/auth/login` 404s from that moment while the second keeps working.

The task asserts every step, plus the DB ground truth: `kiosk.agents.user_id` for the bound key equals the human's id, and the booking landed on the human's own row.

### Roles from an IdP (`rake demo:roles`)

The role an assistant works with is sourced **indirectly, from the bound human's IdP role** — the natural extension of the link ceremony. Both principals use the SAME channel: they sign in at `/users/sign_in` with real Devise, and `kiosk-user-idp-devise` asks the `User` model for `#kiosk_role`, which returns the provider's own `staff_role` column. The salon **owner** carries `owner` there; a plain **customer** carries none:

1. **Owner** links an assistant → the token carries `role: owner` → `salon_calendar` returns the **whole book** (every visitor's booking) plus a **forecasted** € revenue total — summed live from the actual bookings' prices, starting at €0 and growing as visitors book, never a fixed number.
2. **Customer** → the token carries `role: customer` → `salon_calendar` returns **only that customer's own bookings**, and **no forecast**.

The role rides the token, sourced from the operator's identity system — never self-selected by the AI assistant. It is read off the approving human in **both** binding directions: the link ceremony captures it when the human mints the code, and the claim ceremony captures it when the human approves at the verify page — so a customer's assistant cannot widen its scope to the owner's book, whichever door it comes through, and the query's `WHERE` is operator-controlled besides. The verify page names the access it is handing over, so the approval is given knowing what it grants. `rake demo:roles` asserts both views with DB ground-truth on `kiosk.agents.allowed_roles`.

**What the redteam battery actually proves, and what it did not (K-072).** This paragraph used to end «`rake demo:redteam` proves the escalation is BLOCKED», and that sentence was false at head: the battery covered the link direction only, while the claim ceremony took `role`/`scope` from its own **unauthenticated** opening request and baked it into the minted JWT. `role=owner`, approved by a plain customer who was never shown the word, reached a token claiming `owner` and a `salon_calendar` carrying every visitor's bookings plus the owner-only forecast — while the battery exited 0 and said «all 14 scenarios BLOCKED». Four beats now cover the claim direction (`DeviceGrantCannotSelfSelectRole`, `DeviceGrantRoleComesFromTheApprover`, `DeviceGrantVerifyPageNamesTheAccess`, `DeviceGrantRebindCannotEscalate`), including the **rebind**, which a first-bind-only guard would have left open; each was watched failing against the pre-fix engine before it passed. The claim to read this README for is the beat list in `rake demo:redteam`'s own description — not a summary sentence, which is what drifted.

<!-- CI-TASKS:BEGIN — generated by bin/check-ci-tasks --write; do not edit by hand -->
### Which of these run in CI

`.github/workflows/ci.yml` runs the tasks marked **yes** on every push and pull
request; the rest are local-only, for the reason given. This table is generated
from the workflow by `bin/check-ci-tasks`, which fails the build when the
workflow, this table and `lib/tasks/demo.rake` disagree — so a task that carries
assertions cannot go ungated and unexplained.

| Task | Runs in CI | Why not |
|---|---|---|
| `demo:setup` | yes — the job's own setup step |  |
| `demo:walkthrough` | yes |  |
| `demo:isolation` | yes |  |
| `demo:register` | yes |  |
| `demo:binding` | no | timing-sensitive: the account-binding ceremony polls on the advertised RFC 8628 device-grant interval, which flakes on a shared runner. Local-only on every demo that has a poll-timed binding task; atablefor's demo:binding carries no such timing and does run in CI. |
| `demo:roles` | yes |  |
| `demo:redteam` | yes |  |
| `demo:schema` | yes |  |
<!-- CI-TASKS:END -->

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The generator's six kiosk migrations, plus the post-install kiosk migrations the whole fleet carries at identical timestamps (today `drop_kiosk_settlement_raw_jws`; a kiosk schema change after install arrives as a NEW file, never as an edit to a shipped one), plus the Stylish schema (users carry Devise login columns + a `staff_role`; `services` is the evergreen menu; `appointments` accumulate real bookings, capturing the booked `service_id` + `price_cents`) |
| `app/models/{user,salon,service,appointment}.rb` | Trivial AR models; `User` is `database_authenticatable` for the human sign-in and carries `staff_role` (owner); `Service` is a menu item priced in EUR cents |
| `config/initializers/kiosk.rb` | `Kiosk.configure` block — configuration only; it names the two handler controllers, it does not contain them |
| `app/controllers/kiosk/front_desk_controller.rb` | The `salons` / `service_menu` / `availability` / `my_appointments` queries and the role-gated `salon_calendar` forecast — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query`. Not routable: handlers are reached only through the wire |
| `app/controllers/kiosk/appointments_controller.rb` | The `book_appointment` action — same mixin, `kind :action`. Two files is a choice, not a rule: one controller may declare both kinds. Refusals are plain `render json:, status:` naming a wire error code, which the wire re-renders as an RFC 9457 problem document |
| `config/initializers/devise.rb` | Minimal Devise setup — the human session that approves assistant links |
| *(no `c.agent_idp`)* | Deliberate, and the point of the line's absence. An assistant authenticates with the kiosk-pop JWT this engine minted at `/kiosk/auth/register`, `/kiosk/auth/login` or the binding ceremony, verified by the `DefaultAgentIdp` the engine has always shipped as its fallback. The hand-copied `stub_idp.rb` / `jwt_or_stub_idp.rb` pair that used to sit here — and the dev-only `agent:u-…:a-…:r-…` parser it existed to bolt on — are deleted |
| `script/bound_assistant.rb` / `script/devise_session.rb` | The ONE way a driver obtains an AGENT principal and a HUMAN one. Both run the shipped ceremony over real HTTP; both are hand-copied across the demos and held byte-identical by `bin/check-demo-copies` |
| `script/binding_flow.rb` | Account-binding driver: claim ceremony over the real Devise session, link-code redeem, unlink |
| `script/roles_flow.rb` | roles-from-IdP driver: the owner links an assistant + a customer signs in, `salon_calendar` gates on the inherited role |
| `bin/demo` | The walkthrough — POSIX shell, curl-driven, no Ruby in the loop |
| `lib/tasks/demo.rake` | `rake demo:setup`, `rake demo:walkthrough`, `rake demo`, `rake demo:isolation`, `rake demo:register`, `rake demo:binding`, `rake demo:roles`, `rake demo:redteam`, `rake demo:schema` |

## Make it real

The demo bakes in shortcuts that production operators replace. Each transition is small. Two DIFFERENT identity seams are involved — keep them straight:

- **Synthetic users (Alice, Bob) + the staff owner** → real user table populated by your operator's signup flow (the demo already gives them real Devise credentials, and every driver here signs in through the real form like a person would).
- **The AGENT-IdP seam** (`c.agent_idp`) is **not** a shortcut here any more: this demo sets **nothing**, so the engine's own `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp` verifies the kiosk-pop JWTs this very engine minted at `/kiosk/auth/register`, `/kiosk/auth/login` and the binding ceremony — in every environment. It used to override that with a hand-copied composite (`stub_idp.rb` / `jwt_or_stub_idp.rb`) that re-implemented the JWT half more loosely in order to bolt on a dev-only parser turning a self-asserted `agent:u-…:a-…:r-…` string into an identity at any role it asked for, `owner` included; both are deleted (T-104), and `rake demo:redteam`'s `SelfAssertedTokenForgery` beat asserts over the live wire that the shape now resolves to no identity at all. Set this seam **only** to front an EXTERNAL agent-identity issuer (an ID-JAG-style agent-IdP), by subclassing `Kiosk::AgentIdentityProviders::Base` — external agent-IdP adapters are a planned seam, none shipped yet. Whatever you write, the `agent_id` your adapter returns must be a **UUID string**: every `agent_id` column in the `kiosk` schema (and `kiosk.current_agent_id()`) is typed `uuid`, with no `user_id_type`-style knob to widen it, so a foreign issuer's agent identifier has to be mapped onto a local uuid inside the adapter (K-830).
- **The USER-IdP seam** (`c.user_idp`) is **not** a shortcut here any more: this demo wires `kiosk-user-idp-devise` and nothing else, in every environment. It used to compose a role-carrying `X-Staff-Session` SSO stand-in in front of it, and that stand-in is deleted (T-066). Swapping Devise for your real SSO/OIDC session means implementing `Kiosk::UserIdentityProviders::Base` and setting `c.user_idp` — the role your adapter returns is the role the assistant inherits at link time, unchanged. The Devise adapter gets it from `User#kiosk_role`, which this demo maps onto the provider's own `staff_role` column; yours would read it from wherever your identity system keeps it.

## License

Apache-2.0.
