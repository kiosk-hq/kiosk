# kiosk-all

The «I just want to start» meta-gem for the [Kiosk](https://kiosk.tech) framework.

## What it pulls in

`kiosk-all` declares runtime dependencies on the two production data-plane gems:

- **`kiosk-core`** — value types (`Identity`, `Mandate::CheckoutMandate`, `Mandate::PaymentMandate`), abstract adapter base classes, GUC namespace constants, `Kiosk.configure`, protocol version surface
- **`kiosk-server`** — the whole host-side surface: the Kiosk controllers (one path per operation — `GET /kiosk/<query-name>`, `POST /kiosk/<action-name>` — plus `/kiosk/{schema,openapi.json,pay}`), OAuth client registration and the token request with a client assertion and a DPoP proof, JWKS, KYC attestation, `agents.txt` / `agents.json` / `/.well-known/kiosk.json` discovery, the account-binding ceremony, `Kiosk::Server::Executor`, the proof-of-work toll, the Rails engine, the headers middleware and the `kiosk:install` generator

Requiring `kiosk-all` loads `Kiosk` and `Kiosk::Server`.

## Install

```ruby
gem "kiosk-all"
```

That's it for the data plane. Optional pieces you add for your stack:

### Proof-of-work toll — opt-in

The toll needs two gems that `kiosk-all` does not pull in: `kiosk-reputation`
(the policy that sets the toll, and the challenges) and `kiosk-pow-equihash`
(the proof-of-work backend). Add both, and `require` them:

```ruby
gem "kiosk-reputation"
gem "kiosk-pow-equihash"
```

`c.reputation_policy` sets the call toll and `c.registration_pow_count` the
registration toll; both need `c.pow_secret`. The kiosk-server README tells how
to configure them.

### RLS defense-in-depth — opt-in

`kiosk-all` does **not** pull in `kiosk-rls`. Kiosk's isolation comes from the declared queries, actions and `pay`, each authorized in the application; Postgres RLS is available as belt-and-suspenders hardening. Opt in explicitly:

```ruby
gem "kiosk-rls"   # opt-in: DB-level RLS defense-in-depth
```

The gem puts `enable_rls_on` and its siblings on `ActiveRecord::Migration`
itself. A policy reads the request's customer through `kiosk_current_*()` SQL
functions, and the install generator writes the migration that creates them:

```sh
bin/rails generate kiosk:rls:install --user-id-type=uuid
bin/rails db:migrate
```

Give it the `--user-id-type` that you gave `kiosk:install`. See the kiosk-rls
README for the policy language and for the role settings (`app_role`,
`enforce_db_role`), which you configure.

### Test harness — pick one

`kiosk-all` does **not** pull in any test-support gem. Add the one matching your test stack to the dev/test group of your Gemfile:

```ruby
group :test do
  gem "kiosk-rls-rspec"      # if you use RSpec
  # gem "kiosk-rls-minitest" # if you use Minitest
end
```

Why not bundled: test-support gems pull in `rspec`/`minitest` and host-test infrastructure that has no place in your production bundle.

### Adapter gems — pick per market and stack

`kiosk-all` does **not** pull in any adapter gem. Add the ones you actually use:

```ruby
gem "kiosk-user-idp-devise"   # the one shipped sign-in adapter
gem "kiosk-pay-stripe"        # only shipped PSP adapter today
```

Those two are the whole set: `git ls-files 'kiosk-user-idp-*/*.gemspec' 'kiosk-pay-*/*.gemspec'` names one gem each. For a stack or a market neither covers, subclass `Kiosk::UserIdentityProviders::Base` or `Kiosk::PaymentProviders::Base` in your own app and assign it in the initializer.

Why not bundled: each operator picks a payment provider for its market (`kiosk-pay-*`) and an identity adapter for the sign-in it already has (`kiosk-user-idp-*`). A bundle of every adapter would put unused gems into every Gemfile.

## Status

Pre-v1.0 alpha. Tracks the underlying gems' versions.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
