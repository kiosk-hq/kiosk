# Stylish — Kiosk reference demo

Stylish is a hair-styling salon-booking service (stylish.example), Kiosk-enabled. Its one seeded salon is **Combette on Park**. Demonstrates:

- `/.well-known/kiosk.json` discovery
- JWKS endpoint for JWT verification
- Authenticated REST API — **one endpoint per verb**: a query is a `GET /kiosk/<query-name>` with its arguments in the query string, an action is a `POST /kiosk/<action-name>` with its arguments as the JSON body, and the success body IS the result (no envelope). `GET /kiosk/schema`, `GET /kiosk/openapi.json` and `POST /kiosk/pay` keep their own paths; errors are RFC 9457 problem documents whose top-level `code` is what an assistant branches on
- App-layer data isolation (two users, two views of the same table)
- A `book_appointment` Action + a `service_menu` query — an **evergreen service menu**: a small set of services, each with a price in euros, all always bookable (infinite capacity, overbooking allowed — the salon never fills up, so the demo never goes empty or stale and needs no reseed cron). The salon starts with zero bookings; real bookings accumulate as visitors book.
- Human↔assistant account binding over real Devise sessions — the claim ceremony (verify page) and human-minted link codes, asserted by `test/stories/linking_test.rb`
- **Roles from a configured IdP** — stylish has two entrances: a **visitor** books a service off the menu, and the salon **owner** views the whole book. The owner's role, supplied by the operator's own identity system, is inherited by their assistant at link time, and the `salon_calendar` query gates on it (the owner sees every booking with its price, so their assistant can total the revenue the book will bring in; a visitor sees only their own bookings). Asserted by `test/stories/salon_book_test.rb`. (Multi-account is deferred, so a tester acts as a visitor **or** as the owner, not both at once.)

Stylish is the canonical reference shape for personal-services SaaS — barbershops, restaurants, gyms, clinics. Same patterns apply.

> **Auth:** An assistant registers its public key at `/kiosk/oauth/register` (RFC 7591) and gets each token at `/kiosk/oauth/token` with a client assertion (RFC 7523) and a DPoP proof (RFC 9449); `test/stories/registration_test.rb` exercises it end-to-end. The **account-binding ceremony** (RFC 8628) binds a registered assistant to an existing human account after the human — signed in through the demo's real Devise form — approves on the verify page; the assistant polls the token endpoint with its client assertion. The reverse direction is the human-initiated link code (`/kiosk/auth/link` → `/kiosk/auth/claim`), and `/kiosk/auth/unlink` revokes one assistant without touching the human's own session. `/auth.md` describes the methods. `test/stories/linking_test.rb` walks all of it end-to-end.

## Run the demo

The demo lives in the Kiosk monorepo and resolves its gems by path
(`../kiosk-*` in the Gemfile), so run it from its checked-out directory:

```sh
cd kiosk-demo-stylish
bundle install
bin/setup      # seed, then serve the origin
```

`bin/setup` creates the Postgres database, loads the schema + seeds and leaves the origin running for an assistant to drive — see "Watch it work" below.

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3005>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_stylish_development, then seeds the salon
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does.

## What the demo shows

### Account binding (`test/stories/linking_test.rb`)

All over plain HTTP against the live app:

1. **First contact (claim)** — an assistant with a newly registered key opens the ceremony at `/kiosk/oauth/device_authorization`; the human signs in through the real Devise form (cookie + CSRF dance — no fixtures), approves on the verify page (which shows the key's fingerprint, when it asked, and the access the approval hands over), the assistant's poll on `/kiosk/oauth/token`, with its client assertion, mints a token bound to the human's account, and it books an appointment there.
2. **Human-initiated (link)** — the signed-in human mints a link code, a second assistant redeems it at `/kiosk/auth/claim` and sees the same account's appointments. The human then unlinks the first assistant: its token request gets `invalid_client` from that moment while the second keeps working.
3. **Manage page** — the signed-in human names an assistant and caps its spending at `/kiosk/auth/assistants`.

The test asserts every step, and that the booking landed on the human's own row.

### Roles from an IdP (`test/stories/salon_book_test.rb`)

The role an assistant works with is sourced **indirectly, from the bound human's IdP role** — the natural extension of the link ceremony. The owner and a customer use the SAME channel: they sign in at `/users/sign_in` with real Devise, and `kiosk-user-idp-devise` asks the `User` model for `#kiosk_role`, which returns the provider's own `staff_role` column. The salon **owner** carries `owner` there; a plain **customer** carries none:

1. **Owner** links an assistant → the token carries `role: owner` → `salon_calendar` returns the **whole book**: every visitor's booking, each with the price captured when it was booked.
2. **Customer** → the token carries `role: customer` → `salon_calendar` returns **only that customer's own bookings**.

The role rides the token, sourced from the operator's identity system — never self-selected by the AI assistant. It is read off the approving human in **both** binding directions: the link ceremony captures it when the human mints the code, and the claim ceremony captures it when the human approves at the verify page — so a customer's assistant cannot widen its scope to the owner's book, whichever door it comes through, and the query's `WHERE` is operator-controlled besides. The verify page names the access it is handing over, so the approval is given knowing what it grants. `test/stories/salon_book_test.rb` asserts both views.

**What the redteam battery proves, and where to read it.** Both binding directions are covered. The claim direction takes four beats (`DeviceGrantCannotSelfSelectRole`, `DeviceGrantRoleComesFromTheApprover`, `DeviceGrantVerifyPageNamesTheAccess`, `DeviceGrantRebindCannotEscalate`), the **rebind** among them, because a first-bind-only guard leaves the second bind open; each was watched failing against an engine without the fix before it was allowed to pass. **Read the beats in `../kiosk-redteam/suites/stylish.rb`, where each `BATTERY.record` call is one beat.** A summary sentence here is a second statement of what the battery covers, and the battery is the one that runs.

### The salon's clock (`test/book_appointment_test.rb`)

`book_appointment` takes an INSTANT. A haircut happens at a chair, at an address, at an hour, so the clock every wall-clock answer here is written on is **that salon's** — `salons.timezone`, a recorded column. `Europe/Paris` is the ORIGIN DEFAULT: what fills the column, and what dates the published example, which addresses no salon.

**A `slot` without an offset is refused, not completed.** `slot` is declared `format: "date-time"`, which is RFC 3339, and RFC 3339 requires the offset — so the protocol refuses a value without one before the handler runs. An appointment booked an hour off is unrecoverable; a refusal naming its remedy is not.

**The clock decides on the way OUT too, and every row says which one it was.** Every verb that publishes an appointment instant — the `book_appointment` confirmation, its `slot` refusals, `my_appointments`, `salon_calendar` — renders it through `SalonClock.publish` on the booked salon's own zone and publishes that zone as `timezone`, so one booking is one string wherever you read it and an owner reading a book that spans two cities reads each row where its chair is. Underneath, `appointments.slot` is `timestamp with time zone`, the same as the instant columns in atablefor and getgrocery: an invariant about instants belongs in the schema, not in `ActiveRecord.default_timezone`, which is a framework default an operator may change in one line.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and book me a haircut at Combette on Park next Tuesday afternoon.

It discovers the protocol, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`alice@example.com` / `combette-demo-password` and approve it there.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | `users` (Devise login columns + a `staff_role`), the generator's kiosk migrations, Action Cable's table, then the Stylish schema: `salons`, `services` (the evergreen menu) and `appointments`, which accumulate real bookings and capture the booked `service_id` + `price_cents` |
| `app/models/{user,salon,service,appointment}.rb` | Trivial AR models; `User` is `database_authenticatable` for the human sign-in and carries `staff_role` (owner); `Service` is a menu item priced in EUR cents |
| `config/initializers/kiosk.rb` | `Kiosk.configure` block — configuration only |
| `app/controllers/kiosk/` | One controller per resource, each an ordinary Rails controller with `include Kiosk::Handler`: `salons_controller.rb` (`salons`), `services_controller.rb` (`service_menu`), `appointments_controller.rb` (`book_appointment`, `my_appointments`) and `calendar_controller.rb` (the role-gated `salon_calendar`). Handlers are reached only through the protocol. A failed model validation is answered `400 bad_request`, an RFC 9457 problem document in the model's own words |
| `config/initializers/devise.rb` | Minimal Devise setup — the human session that approves assistant links |
| *(no `c.agent_idp`)* | Deliberate, and the point of the line's absence. An assistant authenticates with the DPoP-bound access token this engine's token endpoint (`/kiosk/oauth/token`) minted, verified by the `DefaultAgentIdp` the engine ships as its fallback. Nothing here parses a self-asserted bearer, in any environment |
| `app/models/salon_clock.rb` | The origin's default IANA zone and the one writer every verb publishes an instant with |
| `test/` | `bin/rails test`: `test/stories/` tells each client's and the owner's story over HTTP, as their assistants live it; `book_appointment_test.rb` holds the salon's clock |

## Make it real

The demo bakes in shortcuts that production operators replace. Each transition is small. Two DIFFERENT identity seams are involved — keep them straight:

- **Synthetic users (Alice, Bob) + the staff owner** → real user table populated by your operator's signup flow (the demo already gives them real Devise credentials, and every driver here signs in through the real form like a person would).
- **The AGENT-IdP seam** (`c.agent_idp`) is **not** one of them: this demo sets **nothing**, so the engine's own `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp` verifies the access tokens this very engine minted at `/kiosk/oauth/token` — in every environment. The red-team battery's `SelfAssertedTokenForgery` beat asserts over the live HTTP API that a self-asserted `agent:u-…:a-…:r-…` string resolves to no identity at all — the shape a dev-only parser in front of this seam would turn into an identity at any role it asked for, `owner` included. Set this seam **only** to front an EXTERNAL agent-identity issuer (an ID-JAG-style agent-IdP), by subclassing `Kiosk::AgentIdentityProviders::Base` — the only subclass Kiosk ships is the bundled `DefaultAgentIdp` named above, so an adapter fronting an external issuer is yours to write. Whatever you write, the `agent_id` your adapter returns must be a **UUID string**: every `agent_id` column in the `kiosk` schema (and `kiosk.current_agent_id()`) is typed `uuid`, with no `user_id_type`-style knob to widen it, so a foreign issuer's agent identifier has to be mapped onto a local uuid inside the adapter.
- **The USER-IdP seam** (`c.user_idp`) is **not** one of them: this demo uses `kiosk-user-idp-devise` and nothing else, in every environment. Swapping Devise for your real SSO/OIDC session means implementing `Kiosk::UserIdentityProviders::Base` and setting `c.user_idp` — the role your adapter returns is the role the assistant inherits at link time, unchanged. The Devise adapter gets it from `User#kiosk_role`, which this demo maps onto the provider's own `staff_role` column; yours would read it from wherever your identity system keeps it.

## License

Apache-2.0.
