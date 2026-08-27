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
- **`/.well-known/kiosk.json` with `pay` absent** — no `payment_provider`, no
  `/kiosk/pay` route, no PSP adapter (shared with philslist). The mandate and
  settlement tables ARE installed and stay empty: every demo runs the same
  unmodified `kiosk:install`, so the absence of payments here is the absence of
  a route and a provider, not of schema.
- **Full human web UI** (NOT api_only) — the tutorial-plain scaffold (lists,
  todos, invite, the manage-assistants page) is the video centerpiece.

## Run the demo

The demo lives in the Kiosk monorepo and resolves its gems by path
(`../kiosk-*` in the Gemfile), so run it from its checked-out directory:

```sh
cd kiosk-demo-tudu
bundle install
rake demo
```

`rake demo` creates the Postgres database, loads the schema + seeds, boots the
Rails server, and walks the collaboration happy path (two AI assistants, a shared list
via invite, attribution asserted).

### Prerequisites

- Ruby 4.0+, Postgres reachable (`pg_isready` returns OK)

## What the demo shows

### Collaboration happy path (`rake demo:collab`)

Two PoP-registered AI assistants share a list with no spec change: Alice's AI assistant
creates "Hike" and mints an invite; Bob's AI assistant accepts it and joins as a
member; both add todos. Asserts both AI assistants see the shared list, each todo is
attributed to the AI assistant that added it, and the list has an owner + a member.

### W5 rebind + list transfer (`rake demo:link`)

An assistant registers **headless** and creates the "Hike" list; Alice signs in
through the real Devise form, mints a link code, and the assistant's key redeems
it → **rebind**: the `assistant_claimed` hook migrates the list to Alice. The
pre-link token's principal owns nothing after migration; the assistant re-logs
in and sees the list under Alice; Alice's browser sees it too; Alice ends with
≥2 non-revoked AI assistants. DB ground truth is checked via `psql`.

### Membership isolation (`rake demo:isolation`)

Mallory (a non-member) is walled out: her `my_lists` is empty; `list_todos` /
`list_members` on a private list → 403; a forged `account_id` on her
`create_list` is **refused** — `create_list` declares `additionalProperties:
false` and the principal is not one of its inputs, so the wire answers `400
bad_request` naming the parameter, and her legitimate list still belongs to her
in the DB; used/garbage invite codes → 403. A genuine member is the positive
control (she DOES see and read the list), and after `remove_member` her next
read → 403.

### Adversarial battery (`rake demo:redteam`)

Asserts every attack is BLOCKED (0 BREACH): `CrossTenantRead`, `ForgedUserId`
(the forged `account_id` is refused `400`, not accepted-and-ignored),
`MalformedUuidArg` (400, no SQL internals), `MissingAuth` (401), `GarbageToken`
(401), `UnknownQuery` (404), `UnknownAction` (404), `RetiredWire` (the deleted
0.3 `POST /kiosk/query` and `POST /kiosk/run` are the ordinary 404 an
authenticated caller gets, and `401 unauthenticated` without a bearer, since
auth precedes verb dispatch — no tombstone, no second conformance surface),
`MethodMismatch` (a `GET` at an
action's path is `405` + `Allow: POST`, never a silent 404), plus tudu beats —
`InviteCodeReplay` (403), `RevokedMemberAccess` (403), `RevokedAgentKey` (404),
`PreLinkTokenAfterLink` (401), `NoLoginAddressOnTheRoster` (an assistant bound
to Alice reads the seeded household's roster: display names only, and no
account address anywhere in the body — headless accounts read as an opaque
`member-<hex>` derived from the account UUID, never from an address) and
`ChosenNameNeverTheAddress` (a visitor signs up with a display name and the
list page names them by it).

### Not-only-commerce proof (`rake demo:schema`)

Asserts the schema catalog (queries/actions + non-empty descriptions, including
`invite`/`accept_invite`) **and** that the advertised `capabilities` do **not**
include `pay`, `agents.json` carries no payments block, and `agents.txt` carries
no `Protocols: ap2` / `Payments:` directives.

## AI-assistant surface

Ten verbs, each its own endpoint. A query is a `GET` whose arguments are the
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

Human↔assistant linking is **not** one of the ten verbs — it's the W5 ceremony
(`POST /kiosk/auth/link` mint → `POST /kiosk/auth/claim` redeem), driven by
`script/link_flow.rb`.

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
| `demo:collab` | yes |  |
| `demo:link` | yes |  |
| `demo:isolation` | yes |  |
| `demo:redteam` | yes |  |
| `demo:schema` | yes |  |
<!-- CI-TASKS:END -->

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The canonical kiosk migrations, the full six — every demo ships the identical `kiosk:install` output, so reservations/mandates/settlements are installed here and never written — plus `create_tudu_domain` (lists/memberships/todos/invites) |
| `app/models/{user,list,membership,todo,invite}.rb` | `User` is the account principal (Devise, reused for headless assistant accounts); `memberships` is the many-to-many access surface |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) + the `assistant_creation`/`assistant_claimed` hooks — configuration only; it names the two handler controllers, it does not contain them |
| `app/controllers/kiosk/household_controller.rb` | The `whoami` / `my_lists` / `list_todos` / `list_members` queries — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query`. Not routable: handlers are reached only through the wire |
| `app/controllers/kiosk/todo_lists_controller.rb` | The six actions (`create_list`, `add_todo`, `complete_todo`, `invite`, `accept_invite`, `remove_member`) — same mixin, `kind :action`. Two files is a choice, not a rule: one controller may declare both kinds. Refusals are plain `render json:, status:` naming a wire error code, which the wire renders as the problem document's top-level `code` |
| `app/models/membership.rb`, `app/controllers/concerns/kiosk_membership_gate.rb` | The membership check both wire halves need: `Membership.reachable?` is the access decision (a predicate, no request in it), the concern is the 400/403 refusal around it |
| `app/controllers/lists_controller.rb`, `todos_controller.rb` | The human web UI, running the SAME registered actions as the wire (one shared world) |
| `script/collab_flow.rb` / `script/link_flow.rb` / `script/isolation_flow.rb` / `script/redteam_suite.rb` / `script/schema_flow.rb` | One-JSON-line flow drivers the rake tasks assert on |
| `lib/tasks/demo.rake` | `rake demo:setup`, `:collab`, `:link`, `:isolation`, `:redteam`, `:schema`, `demo` |

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
