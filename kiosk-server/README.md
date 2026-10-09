# kiosk-server

The Kiosk Rails engine — host-side surface for [Kiosk](https://kiosk.tech).


## What's in this release

The full host-side surface is shipped and covered by the gem's own suite
(`bundle exec rspec` in this directory runs it and prints how many examples that is):

- **Wire-protocol controllers** — `VerbController` serves ONE ENDPOINT PER VERB (`GET <mount>/<query-name>`, `POST <mount>/<action-name>`); `WireController` serves the two reserved endpoints `GET <mount>/schema` and `POST <mount>/pay`; `VerbController` also serves `POST <mount>/payment_setup` against the payment provider port, and `PaymentSetupController` the page the provider returns the human to; `VerbController` serves `POST <mount>/request_kyc` against the KYC provider port, and `KycCallbackController` the provider's callback; `OpenApiController` serves a derived OpenAPI description of both at `GET <mount>/openapi.json`; `AuthController` runs the register/login proof-of-possession challenge-response (kiosk-pop — the auth story); JWKS backs stateless token verification.
- **Account binding** — the claim/link ceremonies bind an agent's public key to an existing assistant-account holder's account: OAuth/RFC 8628-shaped device authorization + possession-proof-gated token poll, a session-authenticated verify page and «Link an assistant» page (minimal overridable engine views), link-code mint/redeem, and unlink. Tokens stay kiosk-pop-minted; the durable `DeviceAuthorizationStores::ActiveRecord` store (migration 004) is the default.
- **`Kiosk::Server::Executor`** — dispatches resolved commands to the host's registered queries and Actions.
- **`Kiosk::Handler`** — the mixin an operator includes into a controller of their own to declare verbs as ordinary Rails actions; each declaration's `kind` says whether it is a query or an action, so one controller may declare both. The engine registers the controllers in `app/controllers/kiosk/` at boot and after every reload (see [Declaring queries and actions](#declaring-queries-and-actions)).
- **`Kiosk::Server::PaymentClaim`** — the PSP decorator that keeps §11.6's operator half: one capture per payable row, and a paid state anchored to the capture (see [Payments](#payments)).
- **Agent registration & login** — `AgentRegistration`, `AgentLogin`, `RegistrationPow`, and the pluggable agent-IdP resolve and mint per-agent identities.
- **PoW gate** — `PowGate` enforces the reputation policy's N×PoW challenge-response (soft dependency on `kiosk-reputation`; zero overhead when no policy is set).
- **`Kiosk::Server::WellKnown`** — pure-Ruby builder for `/.well-known/kiosk.json`.
- **`Kiosk::Server::Headers`** + **`HeadersMiddleware`** — Rack middleware that injects `Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client` on `/kiosk/*` responses.
- **`IssuerMiddleware`** — answers `Kiosk.current_issuer` for each request: its origin when that is `c.issuer` or one of `c.additional_origins`, else `c.issuer`. Every origin served is its own operator.
- **The audit sink** — `c.audit_sink` receives one `Kiosk::Server::ActionEvent` per action invocation, success and failure alike. Kiosk stores nothing itself: default is no sink and no emission. See [The audit sink](#the-audit-sink).
- **`Kiosk::Server::SchemaDefinitions`** — SQL generators for the canonical migrations (schema + helpers, identity tables, reservations, device authorizations, mandates).
- **`Kiosk::Server::Engine`** — the Rails engine: one `mount` line draws the full mount-prefixed PROTOCOL surface (the reserved wire, auth, JWKS, KYC, account binding) and nothing else — your own verbs are yours to draw, one explicit route each — installs the root discovery routes when mounted, and auto-injects the headers and issuer middleware (see [Draw the routes](#draw-the-routes)).
- **`Kiosk::Server::ConfigurationExtension`** — adds `mount_path`, `capabilities`, `owner`, `min_client` (and the reputation/PoW slots) to `Kiosk::Configuration`.
- **`bin/rails g kiosk:install`** — the install generator lays down the initializer, the migrations and the wire routes file with the engine mounted in it.

kiosk-server is a Rails gem: it depends on railties, actionpack, activerecord and activesupport (`~> 8.1`), and `require "kiosk/server"` loads them. Pieces such as `WellKnown` and `SchemaDefinitions` still work without a BOOTED Rails app — they just need the framework on the load path.

## Install

> **Not on RubyGems yet** — so every `gem` line below carries `github: "kiosk-hq/kiosk"`, which is what makes it copy-pasteable today. Publication status and the canonical install are stated once, in the monorepo README's [Install](https://github.com/kiosk-hq/kiosk#install) section.

### Preconditions

**Rails `~> 8.1`.** This gemspec pins `railties`, `actionpack`, `activerecord`
and `activesupport` at `~> 8.1`, and it is the only Kiosk gemspec that names
Rails at all. **Rails 7.x and 8.0.x are excluded** — bundler refuses to resolve
against an app on either, so for most "add Kiosk to an existing Rails app" this
is the first thing to check, not a footnote. Older Rails lines are untested
here, so they are not claimed; widening the floor means adding a CI leg first.

**Ruby `>= 3.2.0`**, the floor every Kiosk gemspec declares — and one CI leg
runs the suites on exactly that floor, read out of a gemspec at job time, so it
is a tested number rather than an asserted one.

**PostgreSQL.** The kiosk schema, the identity tables and the optional RLS
backstop are Postgres; no other database is supported.

### The line

```ruby
gem "kiosk-server", github: "kiosk-hq/kiosk"
```

Or, via the meta-gem:

```ruby
gem "kiosk-all", github: "kiosk-hq/kiosk"
```

## Configure

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.audit_sink = ->(event) { AuditRow.create!(**event.to_h) }
end
```

**The default is no sink**: nothing is emitted, nothing is built, and Kiosk
writes nothing to any table of its own. It keeps no audit table of its own at
all, and will not grow one: an audit trail the framework keeps is a retention
policy the framework decided for your customers' data.

### KYC

Set a KYC provider adapter (a `kiosk-kyc-*` gem) and the engine serves
`POST <mount>/request_kyc`, the provider's `POST <mount>/kyc/callback` and the
`kyc_verification` topic, and records the verified attributes against the
person. Declare the attributes your gated actions need; gate with
`Kiosk::Server::Kyc.require!`, which refuses `403 kyc_required` until the
calling principal holds them.

```ruby
Kiosk.configure do |c|
  c.kyc_provider   = Kiosk::KycProviders::Prove.new(operator_id: "acme", intake_secret: ENV["PROVE_SECRET"])
  c.kyc_claims     = %w[age_over_18]
  c.kyc_issuer     = "https://kyc.example"   # the `iss` the provider signs
  c.kyc_public_key = ENV["KYC_PUBLIC_KEY_PEM"]
  c.kyc_audience   = "acme"                  # the `aud` it mints for you
end
```

### Payments

Set a PSP adapter (a `kiosk-pay-*` gem) and the engine serves `pay`. Wrap it in
`Kiosk::Server::PaymentClaim` and the engine keeps §11.6's operator half for you:
it claims your payable row (`unpaid → paying`) before the capture, so a second
`pay` for that row is refused before the processor is reached, and marks it
`paid` when the capture returns. Under the claim it checks the signed cart:
your currency, priced lines that sum to the total, and a total equal to your
own price for the row. That price is the one thing you write — a checker that
answers it from your catalog, given the row and the cart's item lines as
signed, or returns a String saying why the cart is refused.

```ruby
module PriceChecker
  def self.call(order_id, _lines) = Order.where(id: order_id).pick(:total_cents)
end

Kiosk.configure do |c|
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    psp, currency: "eur", table: "orders", reference: "order_id", query: "my_orders",
  )
  c.cart_price_checker = PriceChecker
  c.after_payment      = ->(order_id) { CourierDispatchJob.arm!(order_id) } # optional
end
```

Your per-user query publishes the row's `payment_status` — `paying` as
*pending* — so a capture in flight never reads as *not paid*.


## Upgrading

### The schema

`rails generate kiosk:install` emits the **genesis** — the whole current shape,
as migrations. That is the fresh-install path. Migrations already in
`db/migrate/` are never re-emitted and never edited: a change to the Kiosk
schema arrives as a new file you copy in and migrate, so `db:migrate` on your
existing database transfers only what it has not run.

Each MAJOR publishes its own genesis and drops the previous major's chain, so
**an upgrade crossing a major stops at it.** Install that major, `bin/rails
db:migrate`, then move on — one major at a time. A fresh install at any major
gets that major's genesis and replays no history at all.

MINOR and PATCH releases only ever add files to the chain.

### The configuration

`config/initializers/kiosk.rb` is **yours**. Nothing regenerates it, and no
upgrade edits it.

- **Every new setting ships a working default**, so an initializer you never
  touch keeps working across an upgrade. The generated file is documentation of
  what can be set, not the source of truth for what is set.
- **A setting that cannot have a safe default fails closed at boot, naming
  itself** — `c.pow_secret` with the toll enabled is the worked example. You get
  a `Kiosk::Server::Errors::ConfigurationError` that says which setting is
  missing, at boot, not a wrong answer later.
- **A setting that is removed or renamed keeps a setter that raises**, naming
  what to use instead, so an initializer carrying the old name stops the boot
  instead of being silently ignored.
- **An unknown setting is a `NoMethodError` on `Kiosk::Configuration`**, which
  names the key you typed.

The principle behind all four: generate as little as possible, derive at boot
whatever can be derived, default whatever can be defaulted, and fail closed on
what can be neither.


## Multi-process deployments

The PoW gate keeps spent challenge ids in `c.pow_spent_store`, by default
`Kiosk::Server::PowSpentStores::ActiveRecord`: the `kiosk.pow_spent` table that
`bin/rails g kiosk:install` lays down. Every process and every deploy shares it,
so a proof is accepted once (kiosk.tech `protocol.md` §15.2).

Any other backend works: the contract is `claim(id, exp) → Boolean`,
`release(id)`, `spent?(id)`, `mark_spent(id, exp)`, and `claim` **MUST** be one
atomic operation (Redis `SET … NX EX`, or SQL `INSERT … ON CONFLICT`). A
read-then-write reintroduces exactly the replay race the gate closes.

`c.auth_challenge_store` is in-process, and an operator running more than one
process **MUST** share it: a challenge issued by one worker is invisible to the worker
that gets the `register`/`login`, so the handshake fails **closed** — a
correctly-signed request is rejected, and the AI assistant cannot tell that
apart from a bad key. Above one process it succeeds only when both requests
land on the same worker.

A ready one ships in this gem, backed by a single table:

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.audit_sink = ->(event) { AuditRow.create!(**event.to_h) }
end
```

**The default is no sink**: nothing is emitted, nothing is built, and Kiosk
writes nothing to any table of its own. It keeps no audit table of its own at
all, and will not grow one: an audit trail the framework keeps is a retention
policy the framework decided for your customers' data.

# db/migrate/…_create_kiosk_auth_challenges.rb
class CreateKioskAuthChallenges < ActiveRecord::Migration[8.1]
  def up   = execute(Kiosk::Server::SchemaDefinitions.auth_challenge_sql)
  def down = execute(%(DROP TABLE IF EXISTS "#{Kiosk.configuration.schema}".auth_challenges))
end
```

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.audit_sink = ->(event) { AuditRow.create!(**event.to_h) }
end
```

**The default is no sink**: nothing is emitted, nothing is built, and Kiosk
writes nothing to any table of its own. It keeps no audit table of its own at
all, and will not grow one: an audit trail the framework keeps is a retention
policy the framework decided for your customers' data.

## The audit sink

**Kiosk does not keep an audit trail. It hands you one and gets out of the way.**

Set a callable and it receives one `Kiosk::Server::ActionEvent` for **every
action invocation — successful and failed alike**:

```ruby
# config/initializers/kiosk.rb
Kiosk.configure do |c|
  c.audit_sink = ->(event) { AuditRow.create!(**event.to_h) }
end
```

**The default is no sink**: nothing is emitted, nothing is built, and Kiosk
writes nothing to any table of its own. It keeps no audit table of its own at
all, and will not grow one: an audit trail the framework keeps is a retention
policy the framework decided for your customers' data.

### What the event carries

| field | |
|---|---|
| `action` | the action's wire name |
| `user_id` / `agent_id` | the principal, and the assistant credential that acted (nil when the caller is not an agent) |
| `role` / `actor` | the active role (may be nil), and `"agent"` \| `"human"` \| `"service"` |
| `args` | **the arguments exactly as the handler received them** |
| `status` | `"ok"` or `"error"` |
| `error_class` / `error_message` | the raised error, untruncated, on the `"error"` branch |
| `cause_class` / `cause_message` | the error's own `#cause`, when it has one distinct from itself — the handler's exception behind a wrapper |
| `invoked_at` | when the invocation started |

### The arguments arrive unredacted, and the PII is yours

`event.args` is verbatim: the delivery address, the passenger name, the cart,
the booking reference — whatever your verb takes. **Kiosk does not redact them
for you, and the moment you write them somewhere you are the data controller
for whatever they contain** — retention, encryption at rest, access control and
deletion requests are all yours. That is the deliberate shape of this seam:
Kiosk gives you the capability and does not pretend to have made your privacy
decisions for you.

Withholding them is one call, if that is what you want:

```ruby
# names and JSON types, never values: {"salon_id" => "integer", "slot" => "string"}
c.audit_sink = ->(e) { Rails.logger.info(e.with_arg_types.to_h.to_json) }

# nothing at all
c.audit_sink = ->(e) { Siem.record(e.without_args.to_h) }

# per-field, because only you know which of your fields are hot
c.audit_sink = ->(e) { Siem.record(e.to_h.merge(args: e.args.except(:card_token))) }
```

### What is emitted, and what is not

Actions only. A **query** is not emitted (it changes nothing, and every read
would drown the trail). **`pay`** is not emitted — it already writes the far
richer AP2 mandate trail (`intent_mandates`, `cart_mandates`,
`payment_mandates`, `settlements`). A **refusal that never reached an action**
is not emitted: a 401 with no identity, a 404 for an unregistered name, a 405,
a 400 from argument validation, a 402 from the toll. Nothing was invoked, so
there is nothing to report — this is an action trail, not a request log. Put a
Rack middleware in front of the engine if a request log is what you want.

### A sink that raises does not fail the action

The sink is your code and it is called after the action has already succeeded
or failed. If it raises a `StandardError` the error is logged (`Rails.logger`,
or `warn` outside Rails) and the invocation stands: a booking that succeeded
must not come back as a 500 because a broker was down. Emission also happens
**after** the action's transaction closes, so a slow sink cannot hold a
database transaction open and a failed action's `ROLLBACK` cannot erase the
record of it.

Any `#call`-able works — a lambda, or an instance of a class of yours when the
sink has state. A non-callable is rejected when you configure it, so a typo is
a boot failure rather than an audit trail that silently was never there.


## Draw the routes

The wire has TWO HALVES and the split is by whose surface it is. Both live in a
routes file of their own, reached with Rails' own `draw` — and
`bin/rails g kiosk:install` writes that file and the `draw(:kiosk)` line into
`config/routes.rb` for you, because bundling the gem draws no route at all and
an origin with no mount answers nothing:

```ruby
# config/routes.rb
draw(:kiosk)
```

```ruby
# config/routes/kiosk.rb
mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
```

The generator stops there: it knows no verb of yours. You add one line per verb
under the mount, which is the second half:

```ruby
get  "/kiosk/catalog",     to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "catalog" }
post "/kiosk/place_order", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "place_order" }
```

**The mount draws the PROTOCOL PLANE** — the paths whose shape is the spec's and
not yours. Under the mount: the reserved `schema`, `openapi.json` and `pay`,
`payment_setup` and the `payment_setup/return` page a payment provider sends the
human back to (both answer `501 module_not_served` without a `payment_provider`), the
kiosk-pop auth plane (`auth/challenge`, `auth/register`, `auth/login`,
`auth/revoke`), JWKS (`.well-known/jwks.json`), KYC (`agents/kyc`, and
`request_kyc` and `kyc/callback`, which answer `501 module_not_served` without a
`kyc_provider`) and the whole account-binding ceremony (the RFC 8628 claim wire,
`auth/link`/`claim`/`unlink`, the verify and «Link an assistant» pages). The
engine also installs the ROOT-relative discovery documents — `/agents.txt`,
`/agents.json`, `/auth.md`,
`/.well-known/{agent-configuration,kiosk.json,api-catalog}` — into the host app
via `routes.append`, because the agents.txt standard and RFC 8615 place them at
the origin root, outside any mount prefix. That install happens ONLY when the
engine is mounted: merely bundling the gem adds no routes.

**You draw your OWN VERBS, one explicit route each, and the METHOD FOLLOWS THE
KIND** — GET for a `kind :query`, POST for a `kind :action`. That is what the
protocol says a verb IS, so the routes state it instead of hiding it, and
`bin/rails routes` prints your actual wire. `defaults: { kiosk_verb: … }` hands
the name to the shipped controller; nothing is inferred from the path.

**The mount comes FIRST, and your lines go below it.** Rails dispatches the
first matching route, so everything the engine draws wins over anything written
under it and no verb of yours can shadow `schema`, `pay` or the auth plane. (You
could not declare such a verb anyway — `Kiosk::Handler` refuses a reserved name
at boot.)

A path under the mount that names no route — including a verb called with the
other method — matches nothing, so it is the ordinary 404 Rails answers at any
unrouted path: no `code`, no `hint`. The mount-path middleware still stamps the
version headers on it. If you want the wire's own `404 verb_not_found` there,
draw a catch-all action of your own at the end of your file; the engine does not
draw one, because an assistant reads `GET <mount>/schema` before it dials.
Declared-but-unrouted is the bug class this trade opens: every verb you declare
needs its route.

**The protocol plane comes from the mount and from nowhere else.** Copying those
paths into your routes file by hand is not a supported second way to draw them:
the mount above the copy already answers, so the line is dead, and a protocol
this gem keeps in step with the spec becomes a table you now own. Write your own
verbs; mount the rest.


## Declaring queries and actions

An assistant reaches a provider at ONE ENDPOINT PER VERB: a query is
`GET <mount>/<query-name>` with its arguments in the query string, an action is
`POST <mount>/<action-name>` with its arguments in a JSON body. The operator
decides what those names are and what they mean. `Kiosk::Handler` is the module
that lets a controller answer them, and you draw one route per name — see
[Draw the routes](#draw-the-routes).

Kiosk ships a **mixin, not a base class**. Which superclass a handler controller
has is your decision; the `include` is the whole contract.

Which verb reaches a handler is a property of the **declaration**, not of the
class: `kind :query` puts it on `GET`, `kind :action` on `POST`, and one
controller may declare both — a resource you think of as one thing is one
controller. Split when your domain splits.

```ruby
# app/controllers/kiosk/catalog_controller.rb
class Kiosk::CatalogController < ApplicationController   # your base class, your call
  include Kiosk::Handler

  kind :query
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
  include Kiosk::Handler

  kind :action
  description "Places an order for the assistant's human and reserves the " \
              "chosen delivery window. Nothing is charged until `pay`."
  input_schema  type: "object",
                properties: { items: { type: "array" }, delivery_slot_id: { type: "integer" } },
                required: %w[items delivery_slot_id]
  output_schema type: "object",
                properties: { order_id:    { type: "string" },
                              total_cents: { type: "integer" } },
                required: %w[order_id total_cents]
  def create_order
    order = Orders::Place.call(user_id: kiosk_identity.user_id, params: params)
    render json: { order_id: order.id, total_cents: order.total_cents }
  rescue Orders::SlotTaken => e
    render json: { error: e.message, hint: "call delivery_slots again" }, status: :conflict
  end
end
```

Put handler controllers in `app/controllers/kiosk/`. The engine loads that
directory at boot and after every development reload, and each class that
includes `Kiosk::Handler` registers its verbs, so an edited, added or removed
verb lands without restarting the server.


### What the macros do

Each macro records a declaration; the **next `def`** claims all pending ones and
becomes a wire verb. A method with no declarations above it is not a verb, so
helper methods stay invisible to the wire.

| macro | what it declares |
| --- | --- |
| `kind` | **Required.** `:query` (reached by `GET <mount>/<name>`) or `:action` (`POST <mount>/<name>`). A property of the declaration, so one controller may carry both. There is no default: either one would silently pick an HTTP method for you. `:action` is the DECLARATION name and nothing else: the wire command an action travels under is **`:run`**, so a `kind :action` verb reaches a reputation policy as `verb: :run` (`VerbController#create` → `serve(:run)`; the reserved pay endpoint arrives as `:pay`). Branch on `:run` there, not on `:action` — see `kiosk-reputation`'s README. |
| `reach` | Optional, and the default is the strong one. Whose rows this verb may touch (spec §7.2): `:principal` (default — only the caller's own, or rows that belong to no principal), `:published`, `:consented` or `:role`. Declare nothing and the verb is held to per-principal scoping absolutely; a departure costs one line and is published on the catalog, so an assistant can tell an open board from a scoping bug. |
| `description` | Semantics **only**: what the verb does, how, and what it returns *in meaning*. Never a field list, a type, a required marker or a param name — those live in the schemas. |
| `input_schema` | **Required.** JSON Schema for the params. The input contract: every name, type, enum and range — and the wire coerces and validates every call against it. A verb that takes nothing still declares the empty closed object. |
| `output_schema` | **Required.** JSON Schema for what comes back, so an assistant knows the result shape without a call-and-observe probe — the only machine-readable statement of the answer, now that there is no response envelope. |
| `example_params` | A params object an assistant can copy verbatim. |
| `example_row` | A worked example of the result. |
| `wire_name` | Optional. The name agents call the verb by, when it cannot be the method name. |

The **Required** rows are enforced at declaration time, not at request time: a
verb that omits any of them raises an `ArgumentError` as its class body is read,
so the app fails to boot instead of publishing an incomplete contract.

All of them surface in `GET <mount>/schema`, which is how an assistant discovers
the surface.

**A schema slot may be a proc, when the constraint is a fact about your data.**
Any part of `input_schema`, `output_schema`, `example_params` or `example_row`
may be a zero-arity proc:

```ruby
input_schema type: "object", additionalProperties: false,
             properties: {
               category_slug: { type: "string", enum: -> { Category.pluck(:slug) } },
             }
```

Write the proc, not the plain call. `enum: Category.pluck(:slug)` runs while the
class body is read — which is `db:create`, `db:migrate` and
`assets:precompile` as well as a serving boot, where there is no table to read —
and it captures a list that then goes stale for the life of the process. The
proc is called when the descriptor is SERVED, resolved once and reused for a
short window, and re-resolved after it: so adding a category publishes itself,
with no restart and no deploy. The catalog's `?v=` version moves with it, and
the discovery document republishes the new link within its own minute.
`description`, `kind`, `reach` and `wire_name` are not resolvable — the first is
prose semantics, two are routing facts fixed when the route is drawn, and
`reach` is a security claim about the verb: one computed from your rows could
change under a caller between the catalog it read and the call it made.


### Two things to know

**Handler controllers are not routable.** Do not draw a route at one. They are
reached only through the wire, which is where authentication, the proof-of-work
gate and the transaction live; a direct request answers 404.

### What you get inside a handler

It is an ordinary Rails action. `before_action` filters run, `rescue_from`
applies, `params` is `ActionController::Parameters`, and the answer is whatever
you `render`. On top of that:

- `kiosk_identity` — the `Kiosk::Identity` the wire resolved (`user_id`,
  `agent_id`, `role`, `actor`). The four transaction-local GUCs are already applied to
  the connection, so SQL-side and RLS scoping work whether or not you read it.
- `render_kiosk_page(rows, next_cursor:, total:)` — answer one page of a large
  query. The body stays the bare array every query answers: the cursor leaves as
  an RFC 8288 `Link: <…?cursor=…>; rel="next"` response header and the
  matching-row count as `X-Total-Count`. `Kiosk::Server::Cursor` has an offset
  helper; pass `total:` only when you know it.
- `include Kiosk::Owned` — gives a model with a `user_id` column the scope
  `own`, the current principal's rows. `Kiosk.current_user_id` is the same id,
  for a column with another name.
- `Kiosk::Settlement` and `Kiosk::CartMandate` — read models over the receipts
  `pay` records. `Kiosk::Settlement.own` is the caller's own;
  `Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(order_id: id))`
  is the settlement whose cart names your row by the key your line items carry.
- The handler runs inside the wire's GUC-scoped transaction, so raising rolls
  back — and so does rendering a non-2xx, which the seam converts into a raise.

Errors are Rails' idiom, end to end. The error-**code** vocabulary is the wire
contract — a closed table, not a class hierarchy. Mind which side of the seam
you are on: a handler names a code the Rails way, under `error.code` in the body
it renders, and the wire re-renders that as an RFC 9457
`application/problem+json` document whose `code` is a FLAT top-level member —
`error.code` is the handler-side spelling, `code` is what travels and what an
assistant branches on. Three Rails-native moves cover all of it:

- `render json: {...}, status: :bad_request` — the status becomes its wire
  code (400 `bad_request`, 401 `unauthenticated`, 403 `forbidden`,
  404 `not_found`, 409 `conflict`, 422 `bad_request`, 429 `quota_exceeded`).
- Raise what you would raise anyway. Any exception Rails knows a status for —
  `params.require`, `ActiveRecord::RecordNotFound`, anything your app
  registered in `config.action_dispatch.rescue_responses` (the same registry
  policy libraries use) — is mapped to that status' wire code by one
  `rescue_from` the include installs. Your own `rescue_from` declarations win
  over it. Anything unregistered stays a 500 `action_failed`.
  **The CODE travels; the exception's own SENTENCE does not.** That branch is
  for exceptions you did not author, so the message would be some library's
  wording — actionpack's «param is missing or the value is empty or invalid:
  sku» is what `params.require` puts on a 400 — and it moves when a
  dependency moves. The caller gets a Kiosk sentence and a `hint` for that
  code; the exception's class, message and backtrace go to your `Rails.logger`.
  When you mean to say something to the assistant, say it: render the envelope,
  or raise a `Kiosk::Server::Errors` class with your own `message:` and
  `hint:`. Both carry your words verbatim.
- For a code a bare status cannot name — `rls_denied`, or a *specific* 402
  (`payment_setup_required` vs `payment_failed` vs `pow_required`) — render
  the code explicitly:
  `render json: { error: { code: "rls_denied", message: "…" } },
  status: :forbidden`. It travels verbatim — the code becomes the problem
  document's top-level `code`, the message its `detail` — while a bare 402/500
  is never guessed at. (The gate-style `Kiosk::Server::Errors` classes remain
  raisable too.)


### The initializer holds configuration, not verbs

There is no second way to declare a verb — no block you register from an
initializer. A block there cannot be reloaded, cannot be reached by your
filters, `rescue_from` or strong parameters, and would teach — in the very file
an adopter copies — that Rails does not apply to the surface you expose to
assistants. Write a controller in `app/controllers/kiosk/`, and the initializer
keeps what an initializer is for: the identity providers, the payment provider,
the PoW gates.


## Well-known endpoint (no booted Rails app required)

```ruby
require "kiosk/server"

# The issuer is the AP2 mandate `iss` anchor; the builder refuses to answer
# without it, booted app or not.
Kiosk.configure { |c| c.issuer = "https://api.acme.example" }

doc = Kiosk::Server::WellKnown.build_json(base_url: "https://api.acme.example")
# => '{"kiosk":{"version":"1.0","endpoint":"https://api.acme.example/kiosk",...}}'
```

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
