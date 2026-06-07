# kiosk-all

The «I just want to start» meta-gem for the [Kiosk](https://kiosk.tech) framework.

## What it pulls in

`kiosk-all` declares runtime dependencies on the three production data-plane gems:

- **`kiosk-core`** — value types (`Identity`, `Mandate`, `Event`), abstract adapter base classes, GUC namespace constants, `Kiosk.configure`, protocol version surface
- **`kiosk-rls`** — RLS DSL (`enable_rls_on`, `policy`, migration verbs) and pure-SQL DDL emitter
- **`kiosk-server`** — Rails engine, headers middleware, `/.well-known/kiosk.json` builder, canonical schema-migration SQL

Requiring `kiosk-all` loads `Kiosk`, `Kiosk::RLS`, and `Kiosk::Server`.

## Install

```ruby
gem "kiosk-all"
```

That's it for the data plane. Two more pieces you add per stack:

### Test harness — pick one

`kiosk-all` does **not** pull in any test-support gem. Add the one matching your test stack to the dev/test group of your Gemfile:

```ruby
group :test do
  gem "kiosk-rls-rspec"     # if you use RSpec
  # gem "kiosk-rls-minitest" # if you use Minitest
end
```

Why not bundled: test-support gems pull in `rspec`/`minitest` and host-test infrastructure that has no place in your production bundle.

### Adapter gems — pick per market and stack

`kiosk-all` does **not** pull in any adapter gem. Add the ones you actually use:

```ruby
gem "kiosk-user-idp-devise"      # or -warden, -jwt-bearer, -clerk, -auth0, …
gem "kiosk-pay-stripe"           # or -paddle, …
gem "kiosk-credentials-persona"  # or -onfido, -sumsub, … (only if you need KYC)
```

Why not bundled: there is no «one PSP per provider» or «one IdP per provider» globally; bundling Stripe + Paddle + every IdP would pull five unused gems into every Gemfile. Providers pick per market (`kiosk-pay-*`) and per existing identity stack (`kiosk-user-idp-*`). See design spec §15.4 — this is the same reason `kiosk-pay-all` is deliberately not provided.

## Status

Pre-v0.1 alpha. Tracks the underlying gems' versions.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
