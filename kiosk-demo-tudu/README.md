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
  The spec stays silent on invites *by design* — this proves the query/run
  surface is expressive enough for collaboration with **zero protocol change**.
- **W5 rebind + domain migration** — an assistant works as a HEADLESS account
  (creates the "Hike" list), the human links it, and the shipped
  `assistant_claimed` hook **migrates the list to the human**. First real use of
  the hook in the repo. After linking, one human account holds **≥2
  independently-revocable assistants** (multi-assistant identity).
- **Attribution in a shared space** — each todo records the AI assistant that added it
  (`created_by_agent_id`): "who added the tent? — Bob's assistant."
- **`/.well-known/kiosk.json` with `pay` absent** — no `payment_provider`, no
  `/kiosk/pay` route, no mandate/settlement tables (shared with philslist).
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
`create_list` is ignored (the created row belongs to Mallory); used/garbage
invite codes → 403. A genuine member is the positive control (she DOES see and
read the list), and after `remove_member` her next read → 403.

### Adversarial battery (`rake demo:redteam`)

Asserts every attack is BLOCKED (0 BREACH): `CrossTenantRead`, `ForgedUserId`,
`MissingAuth` (401), `GarbageToken` (401), `UnknownQuery` (404),
`UnknownAction` (404), plus tudu beats — `InviteCodeReplay` (403),
`RevokedMemberAccess` (403), `RevokedAgentKey` (404), `PreLinkTokenAfterLink`
(403).

### Not-only-commerce proof (`rake demo:schema`)

Asserts the schema catalog (queries/actions + non-empty descriptions, including
`invite`/`accept_invite`) **and** that the advertised `capabilities` do **not**
include `pay`, `agents.json` carries no payments block, and `agents.txt` carries
no `Protocols: ap2` / `Payments:` directives.

## AI-assistant surface

| Verb | Name | What it does |
|---|---|---|
| query | `whoami` | The GUC principal + acting AI assistant |
| query | `my_lists` | Lists the caller is a member of (owner or member) |
| query | `list_todos(list_id)` | A member-list's todos, with attribution |
| query | `list_members(list_id)` | A member-list's members + roles |
| run | `create_list(title)` | Create a list; caller becomes owner |
| run | `add_todo(list_id, title)` | Add a todo (attributed to the acting AI assistant) |
| run | `complete_todo(todo_id)` | Mark a todo done (member-gated) |
| run | `invite(list_id)` | Owner-only: mint a single-use, TTL'd invite code |
| run | `accept_invite(code)` | Redeem a code → join as a member |
| run | `remove_member(list_id, account_id)` | Owner-only: cut a member's access |

Human↔assistant linking is **not** a run action — it's the W5 ceremony
(`POST /kiosk/auth/link` mint → `POST /kiosk/auth/claim` redeem), driven by
`link_flow.rb`.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The pruned canonical kiosk migrations — **no** reservations/mandates/settlements — plus `create_tudu_domain` (lists/memberships/todos/invites) |
| `app/models/{user,list,membership,todo,invite}.rb` | `User` is the account principal (Devise, reused for headless assistant accounts); `memberships` is the many-to-many access surface |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) + the `assistant_creation`/`assistant_claimed` hooks + the 4 queries and 6 actions |
| `app/controllers/lists_controller.rb`, `todos_controller.rb` | The human web UI, running the SAME registered actions as the wire (one shared world) |
| `lib/stub_idp.rb` / `lib/jwt_or_stub_idp.rb` | Demo IdP: Kiosk JWTs first, bespoke `agent:u-…:a-…:r-…` fallback |
| `collab_flow.rb` / `link_flow.rb` / `isolation_flow.rb` / `redteam_suite.rb` / `schema_flow.rb` | One-JSON-line flow drivers the rake tasks assert on |
| `lib/tasks/demo.rake` | `rake demo:setup`, `:collab`, `:link`, `:isolation`, `:redteam`, `:schema`, `demo` |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials so the link walkthrough signs in like a
  person would).
- **`StubIdp`** (AI-assistant channel) → registered assistants already flow through
  real Kiosk-issued JWTs; the bespoke fallback shape disappears. The human
  session channel already runs the real `kiosk-user-idp-devise` adapter.

## License

Apache-2.0.
