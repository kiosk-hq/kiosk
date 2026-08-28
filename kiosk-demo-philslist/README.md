# philslist — Kiosk reference demo (NON-COMMERCE)

A free classifieds board, Kiosk-enabled. This is the demo that proves Kiosk is
**not only for commerce**: it exercises the full query + action + `schema` +
identity-binding surface with **no money on the wire at all** — no `pay` verb,
no PSP adapter, no `payment_setup_required` gate, and `pay` absent from
`capabilities`, `agents.json` and `agents.txt`.

The AP2 mandate and settlement TABLES are present and empty, and that is the
canonical install rather than an oversight. Since the MIGRATIONS-FROM-SCRATCH
decision every demo runs the same unmodified `rails g kiosk:install` and gets
the same migrations, so philslist carries `kiosk.reservations`, the four
mandate/settlement tables and `kiosk.kyc_attributes` alongside the identity
ones — `check-demo-copies`'s `ONE_SET_EVERYWHERE` rule makes a per-demo subset
a build failure, because per-demo subsets are how the fleet drifted before.
Those six are not the whole of `db/migrate/`, and the difference is intent
rather than drift: a kiosk schema change that lands AFTER install arrives as a
NEW migration and never as an edit to one that has already shipped, so the fleet
also carries `20260827000002_drop_kiosk_settlement_raw_jws` at the same
timestamp in all seven operator demos. A reader diffing this directory against a
fresh `rails g kiosk:install` should expect the generator's six PLUS whatever
post-install kiosk migrations the fleet has taken since — the same set
everywhere, held there by the same rule.
Nothing writes them here: there is no `pay` route and no PSP, so an empty
`cart_mandates` on this host means what it says.

The same wire contract the commerce demos use for checkout carries a plain
services/data use here.

Demonstrates:

- `/.well-known/kiosk.json` discovery **with `pay` absent** from capabilities —
  and `agents.json` / `agents.txt` carrying no payments block (the honest
  signal this operator takes no money)
- Authenticated REST wire surface — one endpoint per verb
  (`GET /kiosk/browse_listings`, `GET /kiosk/my_listings`,
  `POST /kiosk/post_listing`, `POST /kiosk/edit_listing`,
  `POST /kiosk/close_listing`) beside the public `GET /kiosk/schema` — and
  deliberately **no `/kiosk/pay` route**
- App-layer data isolation on an **owned resource**: any principal may
  `browse_listings` across all sellers, but `my_listings` /
  `edit_listing` / `close_listing` are scoped to
  `owner_id = kiosk.current_user_id()` — the first demo where cross-owner
  **write** denial (not just read exclusion) is the headline
- `post_listing` / `edit_listing` / `close_listing` actions (owner-only writes)
- A **public, read-only classifieds board** at `/` and `/listings` (open
  listings across all owners — title · category · €price · poster). Classifieds
  are public by nature, so a listing an assistant posts over the wire visibly
  appears here on the next refresh
- **A cross-owner board that still publishes no PII.** The board is open by
  design, so its seller column is disclosed to every principal that can
  authenticate. It carries an opaque `seller-<hex>` pseudonym derived from the
  account id — never an address — and the same pseudonym on the wire and on the
  web page. It is **per-seller**, so two listings under one handle are one
  seller (which is what makes the household visible), and reversible by nobody:
  there is no verb that turns a handle back into a person. Contact happens
  through whatever contact detail a seller chose to put in their own listing
  text, so the operator publishes nothing about a seller they did not write
  themselves
- Human↔assistant account binding over real Devise sessions, including the
  **multi-account household** beat: two assistants bound to the SAME account
  (a couple) share one board presence — a listing either posts shows under the
  shared account and to both assistants — each independently revocable, while
  neither can touch a different owner's listing (`rake demo:binding`)

### Before / after

Today you post to a classifieds site through its web form and answer email; a
personal assistant can't. (The craigslist pattern is the shape here — named
only as this contrast, never as the demo.) With Kiosk, the same board exposes
browse / post / edit / close to your assistant as named wire verbs, one
endpoint each — and it can only touch listings you own.

`price_text` is a plain nullable **string** (`"€300"`, `"Free"`, or `NULL`)
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

The walkthrough (`rake demo:walkthrough` — what `rake demo` runs after
`demo:setup`; `bin/demo` under the hood) prints:

1. **Discovery** — the well-known capabilities, asserting `pay` is **absent**
2. **Browse** — `browse_listings` across the open, cross-owner board
3. **Post → edit → close** — the full owned-listing lifecycle over the three
   action endpoints, with `my_listings` reflecting the final state

After the walkthrough finishes, the server is torn down cleanly. Server logs
are at `/tmp/kiosk-philslist-demo.log`.

### Cross-owner isolation (`rake demo:isolation`)

Alice and Bob each post a listing. Then: `browse_listings` returns both owners'
listings (open board); Bob's `my_listings` excludes Alice's and includes his
own; **Bob editing or closing Alice's listing → 403**; and a forged `owner_id`
arg on Bob's `post_listing` is **refused `400 bad_request` naming `owner_id`**,
not accepted-and-ignored — the 0.4 schemas are `additionalProperties: false`, so
the argument never reaches the handler (the legitimate row's DB `owner_id` is
still Bob, taken from the token).

### Adversarial battery (`rake demo:redteam`)

Asserts every attack is BLOCKED (0 BREACH) — every scenario the suite runs, in
its own order: `CrossTenantRead`, `ForgedUserId` (400), `CrossOwnerEdit` (403),
`CrossOwnerClose` (403), `MalformedUuidArg` (400, no SQL internals),
`MissingAuth` (401), `GarbageToken` (401), `SelfAssertedTokenForgery` (401),
`UnknownQuery` (404), `UnknownAction` (404), `RetiredWire` (404),
`MethodMismatch` (405 + `Allow: POST`),
`OutOfEnumFilterIsNotSilentlyReinterpreted` (400 naming the live categories)
`LikeMetacharactersAreEscaped` (an `_` in `keyword` matches an underscore,
not any character) and `NoSellerPiiOnTheOpenBoard` (the open board names a
seller by an opaque `seller-<hex>` pseudonym, carries no account address
anywhere in the response, and keeps one handle per seller). Last comes the one
beat this file does not hand-roll: `DeviceGrantRoleSelfSelection`, shared from
`kiosk-redteam` by every demo — the account-binding claim ceremony's
unauthenticated opening request must refuse a `role` at a value this origin
DECLARES as firmly as an invented one, and a SKIP is scored as a breach here
because this origin declares a role (K-072, K-1128). The task prints the count
it actually ran; that number is the length of this list.

### Not-only-commerce proof (`rake demo:schema`)

Asserts the schema catalog (queries/actions + descriptions) **and** that the
advertised `capabilities` do **not** include `pay`, `agents.json` carries no
payments block, and `agents.txt` carries no `Protocols: ap2` / `Payments:`
directives. The `schema` verb published a byte-identical copy of that set as
`verbs` until it was dropped (T-095) — the two fields were rendered by the same
call, so the module set now has exactly one home. The same beat also asserts
that `GET /kiosk/schema` answers **with no Authorization header at all**: the
catalogue went public in T-094.

### Registration PoW (`rake demo:register`)

Registration is priced even where nothing is sold: a fresh key registering with
no proof gets **402 (`pow_required`)**, solving the challenge with the bundled
solver and resubmitting gets **201**, and the minted token posts a listing
(**200**) — while a bad `category_slug` on that post comes back as a clean
**400** naming the valid categories, not a 500. The point is that the anti-flood
toll is part of the wire contract, not a commerce feature — a free
classifieds board wants it as much as a shop does. Needs python3 + numpy.

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
| `demo:binding` | no | timing-sensitive: the account-binding ceremony polls on the advertised RFC 8628 device-grant interval, which flakes on a shared runner — the same exclusion as stylish's. |
| `demo:redteam` | yes |  |
| `demo:schema` | yes |  |
<!-- CI-TASKS:END -->

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The six canonical `kiosk.*` migrations the install generator emits, unpruned (schema, identity tables, reservations, device_authorizations, mandates, kyc_attributes) — philslist takes no money and gates on no attestation, so the payment and KYC tables sit EMPTY here rather than being edited out — plus the post-install kiosk migrations the whole fleet carries (today `drop_kiosk_settlement_raw_jws`; see above), plus `categories` + `listings` |
| `app/models/{user,category,listing}.rb` | `User` is the account principal and `database_authenticatable`; `Listing.owner_id` is the load-bearing isolation predicate |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) — configuration only; it names the two handler controllers, it does not contain them |
| `app/controllers/kiosk/board_controller.rb` | The `browse_listings` / `my_listings` queries — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query`. Not routable: handlers are reached only through the wire |
| `app/controllers/kiosk/listings_controller.rb` | The `post_listing` / `edit_listing` / `close_listing` actions — same mixin, `kind :action`. Two files is a choice, not a rule: one controller may declare both kinds. Refusals are plain `render json:, status:` naming a wire error `code`, which the wire carries into the RFC 9457 problem document an assistant branches on |
| *(no `c.agent_idp`)* | Deliberate, and the point of the line's absence. An assistant authenticates with the kiosk-pop JWT this engine minted at `/kiosk/auth/register`, `/kiosk/auth/login` or the binding ceremony, verified by the `DefaultAgentIdp` the engine has always shipped as its fallback. The hand-copied `stub_idp.rb` / `jwt_or_stub_idp.rb` pair that used to sit here — and the dev-only `agent:u-…:a-…:r-…` parser it existed to bolt on — are deleted |
| `script/bound_assistant.rb` / `script/devise_session.rb` | The ONE way a driver obtains an AGENT principal and a HUMAN one. Both run the shipped ceremony over real HTTP; both are hand-copied across the demos and held byte-identical by `bin/check-demo-copies` |
| `script/isolation_flow.rb` / `script/redteam_suite.rb` / `script/schema_flow.rb` / `script/binding_flow.rb` / `script/register_flow.rb` | One-JSON-line flow drivers the rake tasks assert on |
| `bin/demo` | The browse→post→edit→close walkthrough (POSIX shell, curl-driven) |
| `lib/tasks/demo.rake` | `rake demo:setup`, `:walkthrough`, `demo`, `:isolation`, `:redteam`, `:schema`, `:binding`, `:register` |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials, and every driver here signs in through the
  real form like a person would).
- **Contact is unrelayed.** A seller reaches a buyer only by publishing a
  contact detail in their own listing text — which works, and is how classifieds
  worked before relays, but it means a seller who wants replies must publish
  something in the clear. A production board adds an operator-relayed message
  verb so neither side hands the other an address; that is designed and tracked
  as T-108, deliberately not built here because a half-built inbox would be a
  worse demo than an honestly-stated absence.
- **The AI-assistant channel** (`c.agent_idp`) is **not** a shortcut here any
  more: this demo sets nothing, so the engine's own `DefaultAgentIdp` verifies
  the kiosk-pop JWTs it minted, in every environment. The bespoke
  `agent:u-…:a-…:r-…` fallback shape — which a dev-only parser turned into an
  identity at any role it asked for — is deleted. Swap this seam only to front
  an EXTERNAL agent-identity issuer (Entra Agent ID, Okta, an ID-JAG-style
  broker), by subclassing `Kiosk::AgentIdentityProviders::Base`; its one hard
  constraint is that the `agent_id` you return must be a **UUID** (K-830).
- **The human session channel** (`c.user_idp`) already runs the real
  `kiosk-user-idp-devise` adapter.

## License

Apache-2.0.
