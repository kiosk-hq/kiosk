# kiosk-server

The Kiosk Rails engine — host-side surface for [Kiosk](https://kiosk.tech).

## What's in this release (pre-v0.1)

Foundational, host-agnostic pieces that don't require booting a Rails app:

- **`Kiosk::Server::WellKnown`** — pure-Ruby builder for `/.well-known/kiosk.json` per spec §3.4
- **`Kiosk::Server::Headers`** + **`HeadersMiddleware`** — Rack middleware that injects `Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client` on `/kiosk/*` responses
- **`Kiosk::Server::SchemaDefinitions`** — SQL generators for the four canonical migrations (schema + helpers, identity tables, actions log, reservations)
- **`Kiosk::Server::Engine`** — Rails engine declaration (conditionally loaded when `Rails::Engine` exists); auto-mounts the headers middleware
- **`Kiosk::Server::ConfigurationExtension`** — adds `mount_path`, `capabilities`, `owner`, `min_client` to `Kiosk::Configuration`

## What's coming

The wire-protocol controllers, the `Kiosk::Executor`, OAuth 2.1 surface, agent registration endpoints, `/kiosk/events` streaming, `bin/rails g kiosk:install`, and `rake kiosk:doctor` all land in follow-up releases.

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
  # c.capabilities = %w[query actions ap2 events]   # default
end
```

## Well-known endpoint (pure Ruby, before controllers ship)

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
