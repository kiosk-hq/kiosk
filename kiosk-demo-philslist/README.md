# philslist — Kiosk reference demo (NON-COMMERCE)

A free classifieds board, Kiosk-enabled. This is the demo that proves Kiosk is
**not only for commerce**: it exercises the full query + action + `schema` +
identity-binding surface with **no money on the wire at all** — no `pay` verb,
no PSP adapter, no `payment_setup_required` gate, and `pay` absent from
`capabilities`, `agents.json` and `agents.txt`.

The AP2 mandate and settlement TABLES are present and empty, and that is the
canonical install rather than an oversight: every demo runs the same unmodified
`rails g kiosk:install`, so philslist carries `kiosk.reservations`, the four
mandate/settlement tables and the KYC tables alongside the identity ones.
`db/migrate/` is that install's output plus the users and classifieds tables,
each created in its final shape.
Nothing writes them here: `POST /kiosk/pay` is drawn like everywhere else —
the mount draws the whole protocol plane — but no `payment_provider` is
configured, so the origin refuses before it reads a mandate and an empty
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
  **deliberately no payments**: philslist configures no `payment_provider`, so
  `pay` is absent from `capabilities`, from `agents.json` and from `agents.txt`,
  and `POST /kiosk/pay` — which the mounted engine draws at every origin, because
  the path is the protocol's — refuses an authenticated caller with `501
  module_not_served`, the origin-wide refusal
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
  neither can touch a different owner's listing (`test/stories/household_test.rb`)

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
(`../kiosk-*` in the Gemfile), so run it from its checked-out directory.

### Prerequisites

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3006>.

On your own machine you need:

- **Ruby 4.0 or newer**, then `bundle install`.
- **Postgres**, reachable — `pg_isready` returns OK.
- **python3 with numpy** — registering an assistant pays an Equihash toll, solved by the bundled `solve.py`.
- **`curl` and `jq`** on PATH — `bin/demo` drives the walkthrough with them.

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_philslist_development, then seeds the board
bin/dev                # serves the origin on http://localhost:3000
bin/demo               # the walkthrough, against that origin
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does.

## What the demo shows

`bin/demo` walks Alice's assistant through the board with `curl`:

1. **Binding** — the assistant registers under the Equihash toll, Alice signs in, and a link code binds it to her account
2. **Discovery** — the well-known capabilities, with no `pay` among them
3. **Browse** — `browse_listings` across the open, cross-owner board
4. **Post → edit → close** — the owned-listing lifecycle over the three
   action endpoints, with `my_listings` showing the final state

The stories in `test/stories/` hold the rest:

- **Isolation** — the board shows every seller's listings and `my_listings` only
  the caller's; editing or closing another seller's listing is **403**; a forged
  `owner_id` on `post_listing` is **refused `400 bad_request`** naming it, and a
  listing's owner and posting assistant come from the token. `browse_listings`
  publishes `reach: published`, and every query that claims `principal` reach
  answers only the caller's rows.
- **Red team** — `script/redteam_suite.rb` attacks the live origin and every
  scenario must be BLOCKED: `CrossTenantRead`, `ForgedUserId`, `CrossOwnerEdit`,
  `CrossOwnerClose`, `MalformedUuidArg`, `MissingAuth`, `GarbageToken`,
  `SelfAssertedTokenForgery`, `UnknownQuery`, `UnknownAction`,
  `UnregisteredVerbIsOrdinaryRefusal`, `MethodMismatch`,
  `OutOfEnumFilterIsNotSilentlyReinterpreted`, `LikeMetacharactersAreEscaped`,
  `NoSellerPiiOnTheOpenBoard`, `ContactDetailsStayOutOfTheRequestLog`, and the
  shared `DeviceGrantRoleSelfSelection`.
- **Not only commerce** — the capabilities are `schema`, `queries` and `actions`
  only: no `pay`, no `events`; `agents.json` and `agents.txt` carry no payment
  terms; the catalogue is public, and its examples satisfy their own schemas.
- **Registration toll** — registering without a proof is **402 `pow_required`**,
  even on a board that sells nothing; with one, the new assistant posts at once.
- **Account binding** — the RFC 8628 device grant binds an assistant to the
  human who approves it; two assistants linked to one household share its
  listings, and unlinking one revokes its tokens — including one minted in the
  same second — while the other keeps working.

### Watch it work

`bin/setup` seeds this demo and leaves the origin running on
<http://localhost:3000>. Then say this to your AI assistant:

> There is a Kiosk origin at http://localhost:3000 — read its
> `/.well-known/kiosk.json` and post an ad for my old bicycle at €80, then show me what else is on
> the board.

It discovers the wire, registers itself and drives the flow. If it asks you to
approve the link, sign in at <http://localhost:3000/users/sign_in> as
`alice@example.com` / `philslist-demo-password` and approve it there.

## Repo tour

| Path | What's there |
|---|---|
| `db/migrate/` | The canonical `kiosk.*` migrations the install generator emits, unpruned (schema, identity tables, reservations, device_authorizations, mandates, KYC, events) — philslist takes no money and gates on no attestation, so the payment and KYC tables sit EMPTY here rather than being edited out — plus `users`, Action Cable's table and `categories` + `listings` |
| `app/models/{user,category,listing}.rb` | `User` is the account principal and `database_authenticatable`; `Listing.owner_id` is the load-bearing isolation predicate |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) — configuration only; it names the two handler controllers, it does not contain them |
| `app/controllers/kiosk/board_controller.rb` | The `browse_listings` / `my_listings` queries — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query`. Not routable: handlers are reached only through the wire |
| `app/controllers/kiosk/listings_controller.rb` | The `post_listing` / `edit_listing` / `close_listing` actions — same mixin, `kind :action`. Two files is a choice, not a rule: one controller may declare both kinds. The operations in `app/operations/` raise `Kiosk::Server::Errors` refusals, which the wire renders as the RFC 9457 problem document an assistant branches on |
| *(no `c.agent_idp`)* | Deliberate, and the point of the line's absence. An assistant authenticates with the kiosk-pop JWT this engine minted at `/kiosk/auth/register`, `/kiosk/auth/login` or the binding ceremony, verified by the `DefaultAgentIdp` the engine has always shipped as its fallback. This demo ships no IdP of its own and recognises no dev-only principal shape: an identity here is a verified JWT or it is nothing |
| `script/bound_assistant.rb` | The ONE way a driver obtains an AGENT principal bound to a seeded human. It runs the shipped ceremony over real HTTP, and is hand-copied across the demos and held byte-identical by `bin/check-demo-copies`. Its HUMAN counterpart is `Kiosk::UserIdentityProviders::DeviseSession`, shipped by `kiosk-user-idp-devise` |
| `script/redteam_suite.rb` | The adversarial battery, run against a live origin |
| `bin/demo` | The browse→post→edit→close walkthrough (curl-driven) |
| `test/` | Minitest tests, run by `bin/rails test`; `test/stories/` drives the origin over HTTP as sellers' assistants |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials, and every driver here signs in through the
  real form like a person would).
- **The AI-assistant channel** (`c.agent_idp`) is **not** a shortcut here: this
  demo sets nothing, so the engine's own `DefaultAgentIdp` verifies the
  kiosk-pop JWTs it minted, in every environment, and nothing accepts a
  self-asserted bearer. Swap this seam only to front
  an EXTERNAL agent-identity issuer (Entra Agent ID, Okta, an ID-JAG-style
  broker), by subclassing `Kiosk::AgentIdentityProviders::Base`; its one hard
  constraint is that the `agent_id` you return must be a **UUID**.
- **The human session channel** (`c.user_idp`) already runs the real
  `kiosk-user-idp-devise` adapter.

## Known limitations

- **Contact is unrelayed.** A buyer reaches a seller only through a contact
  detail the seller typed into the listing text, and that text is public to
  everyone reading the board. The operator relays no messages between them.

## License

Apache-2.0.
