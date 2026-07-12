# kiosk-server

The Kiosk Rails engine — host-side surface for [Kiosk](https://kiosk.tech).

## What's in this release (pre-v0.1)

The full host-side surface is shipped and covered by the gem's own suite (500+ passing specs):

- **Wire-protocol controllers** — `WireController` serves the `/kiosk/query`, `/kiosk/run`, `/kiosk/pay`, `/kiosk/schema` verbs; `AuthController` runs the register/login proof-of-possession challenge-response (kiosk-pop — the auth story, ADR-0008); JWKS backs stateless token verification. (OAuth device-authorization controllers ship but are dormant, not the default auth path.)
- **`Kiosk::Server::Executor`** — dispatches resolved commands to the host's registered queries and Actions.
- **Agent registration & login** — `AgentRegistration`, `AgentLogin`, `RegistrationPow`, and the pluggable agent-IdP resolve and mint per-agent identities.
- **PoW gate** — `PowGate` enforces the reputation policy's N×PoW challenge-response (soft dependency on `kiosk-reputation`; zero overhead when no policy is set).
- **`Kiosk::Server::WellKnown`** — pure-Ruby builder for `/.well-known/kiosk.json`.
- **`Kiosk::Server::Headers`** + **`HeadersMiddleware`** — Rack middleware that injects `Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client` on `/kiosk/*` responses.
- **`Kiosk::Server::SchemaDefinitions`** — SQL generators for the canonical migrations (schema + helpers, identity tables, actions log, reservations, device authorizations, mandates).
- **`Kiosk::Server::Engine`** — Rails engine declaration (conditionally loaded when `Rails::Engine` exists); auto-mounts the headers middleware.
- **`Kiosk::Server::ConfigurationExtension`** — adds `mount_path`, `capabilities`, `owner`, `min_client` (and the reputation/PoW slots) to `Kiosk::Configuration`.
- **`bin/rails g kiosk:install`** — the install generator lays down the initializer and migrations.

The pure-Ruby pieces work without booting a Rails app; the controllers and generator require the Rails engine.

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
  # c.mount_path  = "/kiosk"   # default
  # c.capabilities = %w[schema query run pay]   # optional override; computed from the registry by default (ADR-0009)
end
```

## Well-known endpoint (pure Ruby, no Rails boot required)

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
