# kiosk-user-idp-devise

The Devise user-IdP adapter for [Kiosk](https://kiosk.tech) — for Rails providers that authenticate principals through Devise. Install it explicitly; it is not bundled by `kiosk-all`.

## What it does

Reads the signed-in user from the incoming request's Warden proxy and returns a `Kiosk::Identity` value object the rest of the Kiosk pipeline keys off (RLS GUCs, audit log, Action gating).

The adapter is **agnostic about how the user logged in**: Devise's `database_authenticatable` and `omniauthable` modules both populate the request's Warden user, so the same read covers password login, passwordless magic-link, and every OmniAuth strategy (Google, GitHub, SAML, …).

**Lockable / confirmable handling is implicit.** Devise's `active_for_authentication?` already gates the Warden user, so a locked or unconfirmed user yields no signed-in user and the request fails as unauthenticated. No extra code in the adapter.

## Install

Add the adapter explicitly — the `kiosk-all` meta-gem pulls in only `kiosk-core` and `kiosk-server`, so IdP adapters are opt-in per provider:

```ruby
gem "kiosk-user-idp-devise"
```

The adapter declares no hard runtime dependency on `devise` — it only reads the request's Warden user, and your provider's already-installed Devise satisfies the requirement.

## Wire up

```ruby
# config/initializers/kiosk.rb
require "kiosk/user_identity_providers/devise"

Kiosk.configure do |c|
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  c.roles    = %i[customer]   # at least one — the first is the default
end
```

## Role resolution

Each Kiosk token carries exactly one active role. For a Devise-authenticated human:

1. If the user model defines `#kiosk_role`, that wins.
2. Otherwise, the first symbol in `Kiosk.configuration.roles` is used.
3. If `roles` is empty AND `#kiosk_role` is absent, `Kiosk::UserIdentityProviders::Devise::ConfigurationError` is raised.

```ruby
class User < ApplicationRecord
  devise :database_authenticatable

  # Optional — only if you need per-user role choice.
  def kiosk_role
    support_staff? ? :customer_support : :customer
  end
end
```

## Request shape

The shipped wire passes an `ActionDispatch::Request` (kiosk-server's `IdentityResolution.resolve(request)`). The adapter reads the signed-in user from that request's Warden proxy — `request.env["warden"].user` — which is how Devise exposes the principal to Rack-level components once its middleware has run. A controller-shaped object exposing `#current_user`, and a bare Rack `env` Hash carrying `env["warden"]`, are also accepted for hosts that pass either directly.

## Status

Pre-v0.1 alpha. API surface stable across pre-v0.1 minor bumps.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
