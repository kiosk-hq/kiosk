# kiosk-server

The Kiosk Rails engine — host-side surface for [Kiosk](https://kiosk.tech).


## What's in this release

The full host-side surface is shipped and covered by the gem's own suite (500+ passing specs):

- **Wire-protocol controllers** — `VerbController` serves ONE ENDPOINT PER VERB (`GET <mount>/<query-name>`, `POST <mount>/<action-name>`); `WireController` serves the two reserved endpoints `GET <mount>/schema` and `POST <mount>/pay`; `OpenApiController` serves a derived OpenAPI description of both at `GET <mount>/openapi.json`; `AuthController` runs the register/login proof-of-possession challenge-response (kiosk-pop — the auth story); JWKS backs stateless token verification. (Protocol 0.4 deleted 0.3's multiplexed `POST <mount>/query` and `POST <mount>/run` outright — there is no route left at either path.)
- **Account binding** — the claim/link ceremonies bind an agent's public key to an existing assistant-account holder's account: OAuth/RFC 8628-shaped device authorization + possession-proof-gated token poll, a session-authenticated verify page and «Link an assistant» page (minimal overridable engine views), link-code mint/redeem, and unlink. Tokens stay kiosk-pop-minted; the durable `DeviceAuthorizationStores::ActiveRecord` store (migration 008) is the default.
- **`Kiosk::Server::Executor`** — dispatches resolved commands to the host's registered queries and Actions.
- **`Kiosk::Query` / `Kiosk::Action`** — the mixins an operator includes into a controller of their own to declare verbs as ordinary Rails actions; the engine registers the controllers named in `c.handlers` at boot and after every reload (see [Declaring queries and actions](#declaring-queries-and-actions)).
- **Agent registration & login** — `AgentRegistration`, `AgentLogin`, `RegistrationPow`, and the pluggable agent-IdP resolve and mint per-agent identities.
- **PoW gate** — `PowGate` enforces the reputation policy's N×PoW challenge-response (soft dependency on `kiosk-reputation`; zero overhead when no policy is set).
- **`Kiosk::Server::WellKnown`** — pure-Ruby builder for `/.well-known/kiosk.json`.
- **`Kiosk::Server::Headers`** + **`HeadersMiddleware`** — Rack middleware that injects `Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client` on `/kiosk/*` responses.
- **`Kiosk::Server::SchemaDefinitions`** — SQL generators for the canonical migrations (schema + helpers, identity tables, actions log, reservations, device authorizations, mandates).
- **`Kiosk::Server::Engine`** — the Rails engine: one `mount` line draws the full mount-prefixed surface (wire, auth, JWKS, KYC, account binding), installs the root discovery routes when mounted, and auto-injects the headers middleware (see [Mount the routes](#mount-the-routes)).
- **`Kiosk::Server::ConfigurationExtension`** — adds `mount_path`, `capabilities`, `owner`, `min_client` (and the reputation/PoW slots) to `Kiosk::Configuration`.
- **`bin/rails g kiosk:install`** — the install generator lays down the initializer and migrations.

kiosk-server is a Rails gem: it depends on railties, actionpack, activerecord and activesupport (`~> 8.1`), and `require "kiosk/server"` loads them. Pieces such as `WellKnown` and `SchemaDefinitions` still work without a BOOTED Rails app — they just need the framework on the load path.

## Install

```ruby
gem "kiosk-server"
```

Or, via the meta-gem:

```ruby
gem "kiosk-all"
```

## Configure

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.issuer        = "https://api.acme.example"
  c.user_model    = "User"
  c.user_id_type  = :uuid
  c.roles         = %i[customer master support]
  c.owner         = { name: "Acme Inc.", support: "support@acme.example" }
  # The controllers that declare this origin's verbs — see
  # "Declaring queries and actions". Without them the origin serves no verbs.
  c.handlers      = %w[Kiosk::CatalogController Kiosk::OrdersController]
  # c.mount_path  = "/kiosk"   # default
  # c.capabilities = %w[schema queries actions pay] # optional override; computed from the registry by default
end
```


## Multi-process deployments

One setting is **not** optional once you run more than one process.

The PoW gate enforces that a proof is single-use by recording spent challenge
ids in `c.pow_spent_store`, and the default
(`Kiosk::Server::PowSpentStore`) is an **in-process** Hash. With
`WEB_CONCURRENCY > 1`, or several app hosts behind a load balancer, each worker
keeps its own spent set — so one proof is accepted **once per worker**, and the
single-use property the protocol states (kiosk.tech `protocol.md` §15.2, and the
§16.1 operator profile) no longer holds. An operator running multiple processes
**MUST** point every one of them at the same spent-id store.

A ready one ships in this gem, backed by a single table:

```ruby
# db/migrate/…_create_kiosk_pow_spent.rb
class CreateKioskPowSpent < ActiveRecord::Migration[8.1]
  def up   = execute(Kiosk::Server::SchemaDefinitions.pow_spent_sql)
  def down = execute(%(DROP TABLE IF EXISTS "#{Kiosk.configuration.schema}".pow_spent))
end
```

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.pow_spent_store = Kiosk::Server::PowSpentStores::ActiveRecord.new
end
```

This table is **not** part of `bin/rails g kiosk:install` — a single-process
operator does not need it, so it is added deliberately when you scale out.

Any other backend works: the contract is `claim(id, exp) → Boolean`,
`release(id)`, `spent?(id)`, `mark_spent(id, exp)`, and `claim` **MUST** be one
atomic operation (Redis `SET … NX EX`, or SQL `INSERT … ON CONFLICT`). A
read-then-write reintroduces exactly the replay race the gate closes.

`c.auth_challenge_store` is in-process too, and needs the same treatment for a
different reason: a challenge issued by one worker is invisible to the worker
that gets the `register`/`login`, so the handshake fails *closed*. No shared
adapter ships for it yet — the setter takes any object answering
`put(public_key_pem, nonce, exp)` / `take(public_key_pem, nonce)`.


## Mount the routes

One line. The engine draws the entire surface:

```ruby
# config/routes.rb
mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
```

Under the mount that is the wire (`schema`/`query`/`run`/`pay`), the kiosk-pop
auth plane (`auth/challenge`, `auth/register`, `auth/login`, `auth/revoke`),
JWKS (`.well-known/jwks.json`), KYC attestation (`agents/kyc`) and the whole
account-binding ceremony (the RFC 8628 claim wire, `auth/link`/`claim`/`unlink`,
the verify and «Link an assistant» pages). The engine also installs the
ROOT-relative discovery documents — `/agents.txt`, `/agents.json`, `/auth.md`,
`/.well-known/{agent-configuration,kiosk.json,api-catalog}` — into the host app
via `routes.append`, because the agents.txt standard and RFC 8615 place them at
the origin root, outside any mount prefix. That install happens ONLY when the
engine is mounted: merely bundling the gem adds no routes.

Hand-drawing the same routes in `config/routes.rb` remains the escape hatch —
for a partial surface, or mid-migration. Hand-drawn lines win over the engine's
(Rails dispatches the first matching route), and either path reaches the same
shipped controllers.


## Declaring queries and actions

An assistant reaches a provider at ONE ENDPOINT PER VERB: a query is
`GET <mount>/<query-name>` with its arguments in the query string, an action is
`POST <mount>/<action-name>` with its arguments in a JSON body. The operator
decides what those names are and what they mean. `Kiosk::Query` and
`Kiosk::Action` are the modules that let a controller answer them; the engine
routes every registered name without a routes-file edit.

Kiosk ships a **mixin, not a base class**. Which superclass a handler controller
has is your decision; the `include` is the whole contract.

```ruby
# app/controllers/kiosk/catalog_controller.rb
class Kiosk::CatalogController < ApplicationController   # your base class, your call
  include Kiosk::Query

  description "Lists what the shop has in stock right now, so the assistant " \
              "can decide what to put in a basket."
  input_schema  type: "object", additionalProperties: false,
                properties: { q: { type: "string" } }
  output_schema type: "array",
                items: { type: "object",
                         properties: { sku:         { type: "string" },
                                       price_cents: { type: "integer" } } }
  example_params({ q: "milk" })
  def catalog
    render json: Product.in_stock.search(params[:q]).as_json
  end
end
```

```ruby
# app/controllers/kiosk/orders_controller.rb
class Kiosk::OrdersController < ApplicationController
  include Kiosk::Action

  description "Places an order for the assistant's human and reserves the " \
              "chosen delivery window. Nothing is charged until `pay`."
  input_schema type: "object",
               properties: { items: { type: "array" }, delivery_slot_id: { type: "integer" } },
               required: %w[items delivery_slot_id]
  def create_order
    order = Orders::Place.call(user_id: kiosk_identity.user_id, params: params)
    render json: { order_id: order.id, total_cents: order.total_cents }
  rescue Orders::SlotTaken => e
    render json: { error: e.message, hint: "call delivery_slots again" }, status: :conflict
  end
end
```

Then **name them in the initializer**. That line is what puts the verbs on the
wire:

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.handlers = %w[Kiosk::CatalogController Kiosk::OrdersController]
end
```

A verb registers when its controller's class body is read, and nothing in your
app ever references a handler controller — the wire reaches it *through* the
registry. Name them and the engine takes it from there: it loads and registers
them once at boot in production, and again after every code reload in
development, so an edited, added or removed verb lands without restarting the
server. You never write reload plumbing, and the catalog is identical in every
environment.

Name the classes as **strings**, not constants: the list is re-resolved on each
reload, and a constant written here is the boot generation of the class, stale
the moment Rails reloads it. A name that does not resolve, or a class that
includes neither mixin, fails the boot loudly rather than serving a silent
half-catalog. Handlers put in the registry the other way in
([the initializer API](#the-initializer-still-exists)) need no entry.


### What the macros do

Each macro records a declaration; the **next `def`** claims all pending ones and
becomes a wire verb. A method with no declarations above it is not a verb, so
helper methods stay invisible to the wire.

| macro | what it declares |
| --- | --- |
| `description` | Semantics **only**: what the verb does, how, and what it returns *in meaning*. Never a field list, a type, a required marker or a param name — those live in the schemas (ADR-0023). |
| `input_schema` | JSON Schema for the params. The input contract: every name, type, enum and range. |
| `output_schema` | JSON Schema for what comes back, so an assistant knows the result shape without a call-and-observe probe. |
| `example_params` | A params object an assistant can copy verbatim. |
| `example_row` | A worked example of the result. |
| `wire_name` | Optional. The name agents call the verb by, when it cannot be the method name. |

All of them surface in `GET <mount>/schema`, which is how an assistant discovers
the surface.


### Two things to know

**Handler controllers are not routable.** Do not draw a route at one. They are
reached only through the wire, which is where authentication, the proof-of-work
gate and the transaction live; a direct request answers 404.

**A handler that is not declared is not there at all.** Declaration happens when
the class body is read. Rails eager-loads `app/controllers` in production, so a
handler registers at boot whether or not you listed it — but development
(`config.eager_load = false`) autoloads on first reference, and nothing
references a handler controller, so an origin that names none of them serves
**no verbs at all**: `GET <mount>/schema` returns an empty catalog, every
`query`/`run` answers 404, and `/.well-known/kiosk.json` advertises
`"capabilities": []` (they are computed from the live registry). `c.handlers` is
what closes that: the engine registers the listed classes in both load modes and
rebuilds them on every reload. When neither the list nor the initializer API has
put anything in the registry, the gem says so on the log at boot.


### What you get inside a handler

It is an ordinary Rails action. `before_action` filters run, `rescue_from`
applies, `params` is `ActionController::Parameters`, and the answer is whatever
you `render`. On top of that:

- `kiosk_identity` — the `Kiosk::Identity` the wire resolved (`user_id`,
  `agent_id`, `role`, `actor`). The four transaction-local GUCs are already applied to
  the connection, so SQL-side and RLS scoping work whether or not you read it.
- `render_kiosk_page(rows, next_cursor:)` — answer one page of a large query;
  the cursor reaches the envelope's `next` field. `Kiosk::Server::Cursor` has an
  offset helper.
- The handler runs inside the wire's GUC-scoped transaction, so raising rolls
  back — and so does rendering a non-2xx, which the seam converts into a raise.

Errors are Rails' idiom, end to end. The `error.code` vocabulary is the wire
contract — a closed table, not a class hierarchy — and three Rails-native
moves cover all of it:

- `render json: {...}, status: :bad_request` — the status becomes its wire
  code (400 `bad_request`, 401 `unauthenticated`, 403 `forbidden`,
  404 `not_found`, 409 `conflict`, 422 `bad_request`, 429 `quota_exceeded`).
- Raise what you would raise anyway. Any exception Rails knows a status for —
  `params.require`, `ActiveRecord::RecordNotFound`, anything your app
  registered in `config.action_dispatch.rescue_responses` (the same registry
  policy libraries use) — is mapped to that status' wire code by one
  `rescue_from` the include installs. Your own `rescue_from` declarations win
  over it. Anything unregistered stays a 500 `action_failed`.
- For a code a bare status cannot name — `rls_denied`, or a *specific* 402
  (`payment_setup_required` vs `payment_failed` vs `pow_required`) — render
  the envelope with the code explicit:
  `render json: { ok: false, error: { code: "rls_denied", message: "…" } },
  status: :forbidden`. It travels verbatim; a bare 402/500 is never guessed
  at. (The gate-style `Kiosk::Server::Errors` classes remain raisable too.)


### The initializer holds configuration, not verbs

There is no second way to declare a verb. `Kiosk::Server::Queries.register(name)
{ |args| … }` and its `Actions` counterpart were removed in 0.3 (T-081): a block
in an initializer cannot be reloaded, cannot be reached by your filters,
`rescue_from` or strong parameters, and taught — in the very file an adopter
copies — that Rails does not apply to the surface you expose to assistants.
Write a controller, name it in `c.handlers`, and the initializer keeps what an
initializer is for: the identity providers, the payment provider, the PoW gates.

Every registration is now rebuilt from `c.handlers` on each `to_prepare` pass,
so a handler class you forget to list stops being served even if something else
in your app loads it. The list is the whole truth about what this origin serves.


## Well-known endpoint (no booted Rails app required)

```ruby
require "kiosk/server"
require "json"

doc = Kiosk::Server::WellKnown.build_json(base_url: "https://api.acme.example")
# => '{"kiosk":{"version":"1.0","endpoint":"https://api.acme.example/kiosk",...}}'
```

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
