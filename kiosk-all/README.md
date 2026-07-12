# kiosk-all

The «I just want to start» meta-gem for the [Kiosk](https://kiosk.tech) framework.

## What it pulls in

`kiosk-all` declares runtime dependencies on the two production data-plane gems:

- **`kiosk-core`** — value types (`Identity`, `Mandate`, `Event`), abstract adapter base classes, GUC namespace constants, `Kiosk.configure`, protocol version surface
- **`kiosk-server`** — Rails engine, headers middleware, `/.well-known/kiosk.json` builder, canonical schema-migration SQL

Requiring `kiosk-all` loads `Kiosk` and `Kiosk::Server`.

## Install

```ruby
gem "kiosk-all"
```

That's it for the data plane. Optional pieces you add per stack:

### RLS defense-in-depth — opt-in

`kiosk-all` does **not** pull in `kiosk-rls`. Kiosk's isolation comes from the sanctioned query/run/pay surface with app-layer authz; Postgres RLS is available as belt-and-suspenders hardening. Opt in explicitly:

```ruby
gem "kiosk-rls"           # opt-in: DB-level RLS defense-in-depth
```

See the kiosk-rls README for wiring (`Kiosk::RLS::DSL`, `enable_rls_on`, roles).

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
```

Why not bundled: there is no «one PSP per provider» or «one IdP per provider» globally; bundling Stripe + Paddle + every IdP would pull five unused gems into every Gemfile. Providers pick per market (`kiosk-pay-*`) and per existing identity stack (`kiosk-user-idp-*`) — this is the same reason `kiosk-pay-all` is deliberately not provided.

## Status

Pre-v0.1 alpha. Tracks the underlying gems' versions.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
