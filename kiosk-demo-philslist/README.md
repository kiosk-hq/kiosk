# philslist — Kiosk reference demo (NON-COMMERCE)

A free classifieds board, Kiosk-enabled. This is the demo that proves Kiosk is
**not only for commerce**: it exercises the full `query` + `run` + `schema` +
identity-binding surface with **no money on the wire at all** — no `pay` verb,
no PSP adapter, no mandate/settlement tables, no `payment_setup_required` gate.
The same four-verb contract the commerce demos use for checkout carries a plain
services/data use here.

Demonstrates:

- `/.well-known/kiosk.json` discovery **with `pay` absent** from capabilities —
  and `agents.json` / `agents.txt` carrying no payments block (the honest
  signal this operator takes no money)
- Authenticated REST wire surface (`/kiosk/query`, `/kiosk/run`,
  `/kiosk/schema`) — and deliberately **no `/kiosk/pay` route**
- App-layer data isolation on an **owned resource**: any principal may
  `browse_listings` across all sellers, but `my_listings` /
  `edit_listing` / `close_listing` are scoped to
  `owner_id = kiosk.current_user_id()` — the first demo where cross-owner
  **write** denial (not just read exclusion) is the headline
- `post_listing` / `edit_listing` / `close_listing` actions (owner-only writes)
- Human↔assistant account binding over real Devise sessions, including the
  **multi-account household** beat: a second assistant bound to the same
  account sees and edits the same owner's listings, each independently
  revocable (`rake demo:binding`)

### Before / after

Today you post to a classifieds site through its web form and answer email; a
personal assistant can't. (The craigslist pattern is the shape here — named
only as this contrast, never as the demo.) With Kiosk, the same board exposes
browse / post / edit / close to your assistant over four verbs — and it can
only touch listings you own.

`price_text` is a plain nullable **string** (`"1500 TL"`, `"free"`, or `NULL`)
— display metadata the board never transacts on. A reviewer looking for a
hidden PSP finds only a string column.

## Run the demo

The demo lives in the Kiosk monorepo and resolves its gems by path
(`../kiosk-*` in the Gemfile), so run it from its checked-out directory:

```sh
cd kiosk-demo-philslist
bundle install
rake demo
```

`rake demo` creates the Postgres database, loads the schema + seeds, boots the
Rails server, and walks **browse → post → edit → close** with `curl` + `jq`
output — no payment step, the visible contrast.

### Prerequisites

- Ruby 4.0+, Postgres reachable (`pg_isready` returns OK)
- `curl`, `jq` on PATH

## What the demo shows

The walkthrough (`bin/demo`) prints:

1. **Discovery** — the well-known capabilities, asserting `pay` is **absent**
2. **Browse** — `browse_listings` across the open, cross-owner board
3. **Post → edit → close** — the full owned-listing lifecycle over `run`, with
   `my_listings` reflecting the final state

After the walkthrough finishes, the server is torn down cleanly. Server logs
are at `/tmp/kiosk-philslist-demo.log`.

### Cross-owner isolation (`rake demo:isolation`)

Alice and Bob each post a listing. Then: `browse_listings` returns both owners'
listings (open board); Bob's `my_listings` excludes Alice's and includes his
own; **Bob editing or closing Alice's listing → 403**; and a forged `owner_id`
arg on Bob's `post_listing` is ignored (the created row's DB `owner_id` is Bob).

### Adversarial battery (`rake demo:redteam`)

Asserts every attack is BLOCKED (0 BREACH): `CrossTenantRead`, `ForgedUserId`,
`CrossOwnerEdit` (403), `CrossOwnerClose` (403), `MissingAuth` (401),
`GarbageToken` (401), `UnknownQuery` (404), `UnknownAction` (404).

### Not-only-commerce proof (`rake demo:schema`)

Asserts the schema catalog (queries/actions + descriptions) **and** that the
advertised `capabilities` do **not** include `pay`, `agents.json` carries no
payments block, and `agents.txt` carries no `Protocols: ap2` / `Payments:`
directives. (The `schema` verb's `verbs` field is the fixed four-verb wire
surface and always lists `pay`; the honest pay-absent signal is the computed
capability set, which drops `pay` when no `payment_provider` is configured.)

### Account binding + multi-account household (`rake demo:binding`)

Two flows, one run, all over plain HTTP against the live app:

1. **First contact (claim)** — an assistant with a fresh key opens the ceremony
   at `/kiosk/oauth/device_authorization`; the human signs in through the real
   Devise form (cookie + CSRF dance — no fixtures), approves on the verify
   page, the assistant's possession-proof poll mints a token bound to the
   human's account, and it **posts a listing** there.
2. **Household (link + multi-account)** — the signed-in human mints a link
   code, a **second** assistant redeems it and sees the same account's listings
   — and **edits** the first assistant's listing (a household with separate
   assistants). The human then unlinks the first assistant: its login 404s from
   that moment while the second keeps working.

The task asserts every step, plus the DB ground truth: `kiosk.agents.user_id`
for **both** bound keys equals the human's id, and the posted listing's
`owner_id` is the human.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The pruned canonical kiosk migrations (schema, identity, actions_log, device_authorizations, governance columns) — **no** reservations/mandates/settlements — plus `categories` + `listings` |
| `app/models/{user,category,listing}.rb` | `User` is the account principal and `database_authenticatable`; `Listing.owner_id` is the load-bearing isolation predicate |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) + the browse/my queries and post/edit/close actions |
| `lib/stub_idp.rb` / `lib/jwt_or_stub_idp.rb` | Demo IdP: Kiosk JWTs first, bespoke `agent:u-…:a-…:r-…` fallback |
| `isolation_flow.rb` / `redteam_suite.rb` / `schema_flow.rb` / `binding_flow.rb` / `register_flow.rb` | One-JSON-line flow drivers the rake tasks assert on |
| `bin/demo` | The browse→post→edit→close walkthrough (POSIX shell, curl-driven) |
| `lib/tasks/demo.rake` | `rake demo:setup`, `:walkthrough`, `demo`, `:isolation`, `:redteam`, `:schema`, `:binding`, `:register` |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials so the binding walkthrough signs in like a
  person would).
- **`StubIdp`** (agent channel) → registered assistants already flow through
  real Kiosk-issued JWTs; the bespoke fallback shape disappears. The human
  session channel already runs the real `kiosk-user-idp-devise` adapter.

## License

Apache-2.0.
