# tudu — Kiosk reference demo (COLLABORATIVE, NON-COMMERCE)

A multi-user collaborative todo app, Kiosk-enabled. Like philslist it proves
Kiosk is **not only for commerce** — no money on the wire at all — but where
philslist shows owner-scoped isolation on a public board, tudu shows the shape
critics claim GUC-style patterns can't handle: **membership-based many-to-many
access**, **AI-assistant→AI-assistant collaboration expressed entirely at the app layer**, and
the **W5 account-link rebind** that migrates an assistant's work to a human.

Demonstrates:

- **Membership-based isolation** — not "my rows" but "rows of lists I'm a member
  of". Every list/todo query & action gates on
  `EXISTS (SELECT 1 FROM memberships WHERE list_id = :id AND account_id =
  kiosk.current_user_id())`; a non-member gets `403`, not `404`, so probing
  can't enumerate ids.
- **AI-assistant→AI-assistant invites, pure app-layer** — an owner mints a single-use, TTL'd,
  hashed collaboration code (`invite`); the recipient's assistant redeems it
  (`accept_invite`) to join as a member; `remove_member` cuts access instantly.
  The spec stays silent on invites *by design* — this proves the per-verb wire
  is expressive enough for collaboration with **zero protocol change**.
- **W5 rebind + domain migration** — an assistant works as a HEADLESS account
  (creates the "Hike" list), the human links it, and the shipped
  `assistant_claimed` hook **migrates the list to the human**. First real use of
  the hook in the repo. After linking, one human account holds **≥2
  independently-revocable assistants** (multi-assistant identity).
- **Attribution in a shared space** — each todo records the AI assistant that added it
  (`created_by_agent_id`): "who added the tent? — Bob's assistant."
- **`/.well-known/kiosk.json` with `pay` absent** — no `payment_provider` and no
  PSP adapter (shared with philslist). `POST /kiosk/pay` is drawn, because the
  mounted engine draws the whole protocol plane at every origin, and it refuses
  an authenticated caller with `501 module_not_served`; nothing advertises it.
  The mandate and settlement tables ARE installed and stay empty: every demo
  runs the same unmodified `kiosk:install`, so the absence of payments here is
  the absence of a provider, not of schema and not of a path.
- **Full human web UI** (NOT api_only) — the tutorial-plain scaffold (lists,
  todos, invite, the manage-assistants page) is the video centerpiece.

## Running it

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3007>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_tudu_development, then seeds the household
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does.

## What the demo shows

### Collaboration (`test/wire/collab_test.rb`)

Two PoP-registered AI assistants share a list with no spec change: Alice's AI assistant
creates "Hike" and mints an invite; Bob's AI assistant accepts it and joins as a
member; both add todos. Asserts both AI assistants see the shared list, each todo is
attributed to the AI assistant that added it, and the list has an owner + a member.

**And the deadline is the sharpest clock case this fleet has.** «Tomorrow at
two» is said by one person and read by another: share the list and the second
reader is in another city, so there is no single wall-clock string correct for
both. So `todos.due_at` is a `timestamptz` holding one absolute MOMENT, an
assistant resolves «tomorrow at two» on the clock of the human who said it
before it reaches the wire, and every read renders it in the zone the CALLER
declares in the `Kiosk-Timezone` header — with `timezone` on the row saying
which. The test asserts exactly that: Alice reads it in `Europe/Istanbul`, Bob
reads the same todo in `America/New_York`, the two labels differ, and the
instant does not. A caller that declares nothing gets this household's own
clock, stated in the row rather than assumed. And a `due_at` carrying no offset
is refused `400`: it is the one value that would mean two different moments to
two readers with nothing on the wire to say so, and completing it here would
pick one of them silently.

**And Alice's assistant is told, over `<endpoint>/events`, without asking.** It
holds the list's `todo` and `list_membership` topics, plus `todo` with no
subject: Bob joining arrives live, Bob's todo added while it was disconnected
arrives on reconnecting with `since`, Bob ticking off Alice's todo arrives live as
`completed`, and Bob's removal arrives live while his
own subscription to the list is withdrawn (`unsubscribed`, `reach_revoked`).
Every delivered `data` is checked against the `payload_schema` the origin serves.

### W5 rebind + list transfer (`test/wire/link_test.rb`)

An assistant registers **headless** and creates the "Hike" list; Alice signs in
through the real Devise form, mints a link code, and the assistant's key redeems
it → **rebind**: the `assistant_claimed` hook migrates the list to Alice. Every
pre-link token stops verifying, including one minted in the rebind's own second;
the assistant re-logs in and sees the list under Alice; Alice's browser sees it
too; a second linked AI assistant leaves the first one bound. Re-linking an
assistant already bound to Alice moves nothing and destroys nothing.

### Membership isolation (`test/wire/isolation_test.rb`)

Mallory (a non-member) is walled out: her `my_lists` is empty; `list_todos` /
`list_members` on a private list → 403; a forged `account_id` on her
`create_list` is **refused** — `create_list` declares `additionalProperties:
false` and the principal is not one of its inputs, so the wire answers `400
bad_request` naming the parameter, and her legitimate list still belongs to her
in the DB; used/garbage invite codes → 403. A genuine member is the positive
control (she DOES see and read the list), and after `remove_member` her next
read → 403.

### Adversarial battery (`script/redteam_suite.rb`)

Asserts every attack is BLOCKED (0 BREACH): `CrossTenantRead`, `ForgedUserId`
(the forged `account_id` is refused `400`, not accepted-and-ignored),
`MalformedUuidArg` (400, no SQL internals), `MissingAuth` (401), `GarbageToken`
(401), `UnknownQuery` (404), `UnknownAction` (404),
`UnregisteredVerbIsOrdinaryRefusal` (a POST to a name no verb registers draws
no route: the ordinary 404 any undrawn path gets, bearer or not),
`MethodMismatch` (a `GET` at an action's path draws no route either, so it is
the same plain 404 and the write never runs), plus tudu beats —
`InviteCodeReplay` (403), `RevokedMemberAccess` (403), `RevokedAgentKey` (404),
`PreLinkTokenAfterLink` (401), `NoLoginAddressOnTheRoster` (an assistant bound
to Alice reads the seeded household's roster: display names only, and no
account address anywhere in the body — headless accounts read as an opaque
`member-<hex>` derived from the account UUID, never from an address) and
`ChosenNameNeverTheAddress` (a visitor signs up with a display name and the
list page names them by it). Plus `DeviceGrantRoleSelfSelection`, the shared
`kiosk-redteam` beat every demo runs: the account-binding ceremony's
unauthenticated opening request refuses `role`/`scope` at a DECLARED value
as well as an invented one, while the role-less request still opens it.

### Not-only-commerce proof (`test/wire/discovery_test.rb`)

Asserts the schema catalog (queries/actions + non-empty descriptions, including
`invite`/`accept_invite`) **and** that the advertised `capabilities` do **not**
include `pay`, `agents.json` carries no payments block, and `agents.txt` carries
no `Protocols: ap2` / `Payments:` directives.

### In-process tests

The rest of `test/` runs against the test database without a server: the reader clock a
deadline is published on, the list-access refusals, and the write Operations —
an invite is single-use, the last owner cannot be removed, a deadline is stored
as one instant.

## AI-assistant surface

Every verb gets its own endpoint. A query is a `GET` whose arguments are the
query string and whose success body is a bare JSON array; an action is a `POST`
whose arguments are the JSON body and whose success body is its own object. A
refusal is an RFC 9457 problem document — branch on its top-level `code`.

| Endpoint | Name | What it does |
|---|---|---|
| `GET /kiosk/whoami` | `whoami` | The GUC principal + acting AI assistant |
| `GET /kiosk/my_lists` | `my_lists` | Lists the caller is a member of (owner or member) |
| `GET /kiosk/list_todos?list_id=…` | `list_todos(list_id)` | A member-list's todos, with attribution |
| `GET /kiosk/list_members?list_id=…` | `list_members(list_id)` | A member-list's members (display names, never login addresses) + roles |
| `POST /kiosk/create_list` | `create_list(title)` | Create a list; caller becomes owner |
| `POST /kiosk/add_todo` | `add_todo(list_id, title)` | Add a todo (attributed to the acting AI assistant) |
| `POST /kiosk/complete_todo` | `complete_todo(todo_id)` | Mark a todo done (member-gated) |
| `POST /kiosk/invite` | `invite(list_id)` | Owner-only: mint a single-use, TTL'd invite code |
| `POST /kiosk/accept_invite` | `accept_invite(code)` | Redeem a code → join as a member |
| `POST /kiosk/remove_member` | `remove_member(list_id, account_id)` | Owner-only: cut a member's access |

Human↔assistant linking is **not** one of the verbs in the table above — it's
the W5 ceremony (`POST /kiosk/auth/link` mint → `POST /kiosk/auth/claim`
redeem), driven by `test/wire/link_test.rb`.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and make me a list for next month's move and add the first five things
> I have to do.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`alice@example.com` / `tudu-demo-password` and approve it there.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The canonical kiosk migrations: the full `kiosk:install` set — every demo ships that output unmodified, so reservations/mandates/settlements are installed here and never written — plus `users`, Action Cable's table and `create_tudu_domain` (lists/memberships/todos/invites) |
| `app/models/{user,list,membership,todo,invite}.rb` | `User` is the account principal (Devise, reused for headless assistant accounts); `memberships` is the many-to-many access surface |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) + the `assistant_creation`/`assistant_claimed` hooks — configuration only; it names the two handler controllers, it does not contain them |
| `app/controllers/kiosk/household_controller.rb` | The `whoami` / `my_lists` / `list_todos` / `list_members` queries — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query`. Not routable: handlers are reached only through the wire |
| `app/controllers/kiosk/todo_lists_controller.rb` | The six actions (`create_list`, `add_todo`, `complete_todo`, `invite`, `accept_invite`, `remove_member`) — same mixin, `kind :action`. Two files is a choice, not a rule: one controller may declare both kinds. An Operation refuses by raising a `Kiosk::Server::Errors` class, which the wire renders as a problem document |
| `app/models/membership.rb`, `app/operations/list_access.rb` | Who may reach a list: `Membership.own` is the principal's memberships, `ListAccess` the 403 a stranger gets |
| `app/controllers/lists_controller.rb`, `todos_controller.rb` | The human web UI, calling the same Operations as the wire; a refusal becomes a flash |
| `script/redteam_suite.rb` | The adversarial battery, runnable against any tudu origin |
| `test/` | `bin/rails test`; `test/wire/` drives a live origin over HTTP |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials so the link walkthrough signs in like a
  person would).
- **Nothing in the AI-assistant channel** → there is nothing to replace. This
  demo configures no `c.agent_idp`, so the engine verifies its own kiosk-pop
  JWTs through `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp`; set
  one only to front an EXTERNAL agent-identity issuer. The human session
  channel already runs the real `kiosk-user-idp-devise` adapter.

## License

Apache-2.0.
