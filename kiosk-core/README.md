# kiosk-core

Core abstractions for the [Kiosk](https://kiosk.tech) framework.

## What is Kiosk

Kiosk turns a Postgres-backed business app into an agent surface: REST endpoint, multi-agent identity per user, app-layer-authorized data plane with opt-in Postgres RLS defense-in-depth, AP2 mandate trail. Alpha. Apache-2.0.

## What is kiosk-core

The foundation. Defines:

- **Value types** — `Kiosk::Identity`, `Kiosk::Mandate` (intent / cart / payment)
- **Abstract base classes** that adapter gems extend:
  - `Kiosk::AgentIdentityProviders::Base`
  - `Kiosk::UserIdentityProviders::Base`
  - `Kiosk::PaymentProviders::Base`
- **Postgres GUC namespace constants** — `Kiosk::GUC`
- **Protocol-version surface** — `Kiosk::Protocol` (API version, min client, response header names, well-known path)
- **Configuration** — `Kiosk.configure { |c| ... }`

No Rails dependency. Loadable in any Ruby app. Heavier `kiosk-server`, `kiosk-rls`, and adapter gems build on top of this.

## Install

```ruby
gem "kiosk-core"
```

For the full provider stack, install the meta-gem:

```ruby
gem "kiosk-all"
```

## Status

Pre-v1.0 alpha. Wire-protocol semver stability begins at v1.0; pre-v1.0 minor bumps may break compatibility (CHANGELOG.md tracks).

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech) — landing + docs
- [Design spec](https://github.com/kiosk-hq) — full architecture
- [Issue tracker](https://github.com/kiosk-hq/kiosk-core/issues)
