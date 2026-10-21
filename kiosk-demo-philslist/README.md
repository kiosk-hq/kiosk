# philslist — Kiosk reference demo (NON-COMMERCE)

A free classifieds board, Kiosk-enabled. This is the demo that proves Kiosk is
**not only for commerce**: it exercises the full query + action + `schema` +
identity-binding surface with **no money on the wire at all** — no `pay` verb,
no PSP adapter, no `payment_setup_required` gate, and `pay` absent from
`capabilities`.

The AP2 mandate and settlement TABLES are present and empty, and that is the
canonical install rather than an oversight: every demo runs the same unmodified
`rails g kiosk:install`, so philslist carries the three
mandate/settlement tables and the KYC tables alongside the identity ones.
`db/migrate/` is that install's output plus the users and classifieds tables,
each created in its final shape.
Nothing writes them here: `POST /kiosk/pay` is drawn like everywhere else —
the mount draws the whole protocol plane — but no `payment_provider` is
configured, so the origin refuses before it reads a mandate and an empty
`checkout_mandates` on this host means what it says.

The same wire contract the commerce demos use for checkout carries a plain
services/data use here.

Demonstrates:

- `/.well-known/kiosk.json` discovery **with `pay` absent** from capabilities —
  the honest signal this operator takes no money
- Authenticated REST wire surface — one endpoint per verb
  (`GET /kiosk/browse_listings`, `GET /kiosk/my_listings`,
  `POST /kiosk/post_listing`, `POST /kiosk/edit_listing`,
  `POST /kiosk/close_listing`) beside the public `GET /kiosk/schema` — and
  **deliberately no payments**: philslist configures no `payment_provider`, so
  `pay` is absent from `capabilities`, and `POST /kiosk/pay` — which the mounted engine draws at every origin, because
  the path is the protocol's — refuses an authenticated caller with `501
  module_not_served`, the origin-wide refusal
- App-layer data isolation on an **owned resource**: any signed-in assistant may
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
  design, so its seller column is disclosed to every assistant that can
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

From this directory:

```
bin/rails db:reset     # DROPS and recreates kiosk_philslist_development, then seeds the board
bin/dev                # serves the origin on http://localhost:3000
bin/rails test         # the tests; CI runs exactly this
```

`bin/setup` does the first two. The tests drive the origin over HTTP the way an
assistant does.

## What the demo shows

The stories in `test/stories/` show it:

- **Isolation** — the board shows every seller's listings and `my_listings` only
  the caller's; editing or closing another seller's listing is **403**; a forged
  `owner_id` on `post_listing` is **refused `400 bad_request`** naming it, and a
  listing's owner and posting assistant come from the token. `browse_listings`
  publishes `reach: published`, and every query that claims `principal` reach
  answers only the caller's rows.
- **Red team** — `../kiosk-redteam/suites/philslist.rb` attacks the live origin and every
  scenario must be BLOCKED: `CrossTenantRead`, `ForgedUserId`, `CrossOwnerEdit`,
  `CrossOwnerClose`, `MalformedUuidArg`, `MissingAuth`, `GarbageToken`,
  `SelfAssertedTokenForgery`, `UnknownQuery`, `UnknownAction`,
  `UnregisteredVerbIsOrdinaryRefusal`, `MethodMismatch`,
  `OutOfEnumFilterIsNotSilentlyReinterpreted`, `LikeMetacharactersAreEscaped`,
  `NoSellerPiiOnTheOpenBoard`, `ContactDetailsStayOutOfTheRequestLog`, and the
  shared `DeviceGrantRoleSelfSelection`.
- **Not only commerce** — the capabilities are `schema`, `queries` and `actions`
  only: no `pay`, no `events`; the catalogue is public, and its examples satisfy their own schemas.
- **Registration toll** — registering without a proof is **402 `pow_required`**,
  even on a board that sells nothing. A board records no spend, so each access
  token (one hour) also pays one proof on its first call.
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
| `db/migrate/` | The canonical `kiosk.*` migrations the install generator emits, unpruned (schema, identity tables, device_authorizations, mandates and settlements, KYC attributes, events, pow_spent, revocations, visits, refunds) — philslist takes no money and gates on no attestation, so the payment and KYC tables sit EMPTY here rather than being edited out — plus `users`, Action Cable's table and `categories` + `listings` |
| `app/models/{user,category,listing}.rb` | `User` is a seller's account and `database_authenticatable`; `Listing.owner_id` is the load-bearing isolation predicate |
| `config/initializers/kiosk.rb` | `Kiosk.configure` (NO `payment_provider`) — configuration only; the handler controller is separate |
| `app/controllers/kiosk/listings_controller.rb` | Every verb on listings: the `browse_listings` / `my_listings` queries and the `post_listing` / `edit_listing` / `close_listing` actions — an ordinary Rails controller with `include Kiosk::Handler`, each declaration marked `kind :query` or `kind :action`, reached only through the wire. A refusal raises a `Kiosk::Server::Errors` error (`Listing.own!` does), which the wire renders as the RFC 9457 problem document an assistant branches on |
| *(no `c.agent_idp`)* | Deliberate, and the point of the line's absence. An assistant authenticates with the DPoP-bound access token this engine's token endpoint (`/kiosk/oauth/token`) minted, verified by the `DefaultAgentIdp` the engine has always shipped as its fallback. This demo ships no IdP of its own and recognises no dev-only identity shape: an identity here is a verified JWT or it is nothing |
| `test/` | Minitest tests, run by `bin/rails test`; `test/stories/` drives the origin over HTTP as sellers' assistants |

## Make it real

The demo bakes in shortcuts production operators replace:

- **Synthetic accounts (Alice, Bob)** → your real user table (the demo already
  gives them real Devise credentials, and every driver here signs in through the
  real form like a person would).
- **The AI-assistant channel** (`c.agent_idp`) is **not** a shortcut here: this
  demo sets nothing, so the engine's own `DefaultAgentIdp` verifies the
  access tokens it minted, in every environment, and nothing accepts a
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
