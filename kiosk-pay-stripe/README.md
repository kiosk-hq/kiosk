# kiosk-pay-stripe

Stripe PSP adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::PaymentProviders::Base` over Stripe PaymentIntents.

## Install

> **Not on RubyGems yet** — so every `gem` line below carries `github: "kiosk-hq/kiosk"`, which is what makes it copy-pasteable today. Publication status and the canonical install are stated once, in the monorepo README's [Install](https://github.com/kiosk-hq/kiosk#install) section.

There is no default PSP — `Kiosk::Configuration#payment_provider` starts `nil`
— and neither `kiosk-server` nor `kiosk-all` pulls an adapter in, so taking
payments means adding this one yourself:

```ruby
gem "kiosk-pay-stripe", github: "kiosk-hq/kiosk"
```

Bundler brings the two runtime dependencies with it: `kiosk-core` and Stripe's
own `stripe` gem. Nothing loads until you require the adapter, and the adapter
does nothing until it is assigned to `payment_provider` — both in the block
below.

You also need a secret key for the **provider's own** Stripe account
(`sk_test_…` for the PoC; test mode only, see below). The buyer's card is
saved on that account, so there is no Kiosk-side Stripe account to configure.

## Model: card-on-file + off_session (SetupIntent)

The headline flow saves the buyer's card ONCE on the *provider's* Stripe
account as a Customer + PaymentMethod (keyed to the synthetic principal /
`user_id`). Subsequent purchases are charged `off_session`
(merchant-initiated) against that saved card — the assistant authorizes,
never presents a card.

The `principal → Stripe Customer` mapping lives in the host's `stripe_customers`
table, through `Kiosk::PaymentProviders::Stripe::CustomerRecord`. The install
generator writes the migration that creates this table. Give it the same
`--user-id-type` that you gave `kiosk:install`:

```sh
bin/rails generate kiosk:pay_stripe:install --user-id-type=uuid
bin/rails db:migrate
```

```ruby
require "kiosk/payment_providers/stripe"

Kiosk.configure do |c|
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key: ENV["STRIPE_SECRET_KEY"], # sk_test_… for the PoC
  )
end
```

An app that already keeps the mapping elsewhere passes `customer_resolver:
->(user_id) { … }` and `customer_saver: ->(user_id, cus_id) { … }` instead.

The saver replaces any earlier mapping for the principal: when Stripe no
longer has the mapped Customer (deleted, or from another account), the adapter
treats the principal as having no saved card and saves a fresh Customer.

Card-setup handshake (see the Payment section of the spec):

- `setup_required?(user_id:)` — true when the principal must set up a card
  before a charge can proceed.
- `setup_url(user_id:, return_url:)` — hosted Stripe Checkout URL (`mode: "setup"`). The
  human opens it in a browser (NOT the chat) to enter their card on Stripe's
  hosted page; Stripe then redirects them to kiosk-server's
  `<mount>/payment_setup/return` page, which kiosk-server passes as `return_url`. The gem
  never sees card data. **Stable across polls:** an already-outstanding
  (`status: open`, same `return_url`) setup session is reused, so an assistant
  polling readiness keeps handing its human the SAME link instead of a fresh
  one per poll. One exception, and it is logged rather than hidden: if the
  lookup itself errors, the adapter cannot tell "no outstanding session" from
  "did not find out", so it mints a fresh session (the probe keeps answering)
  and warns that the url is not stable until that clears.
- `setup_return_user_id(params)` — the principal whose Checkout Session the
  return page's `session_id` names, asked of Stripe; kiosk-server then pushes the
  `payment_setup` event once `setup_required?` answers false.
- `saved_method?(user_id:)` — true once the resolved Customer has a usable
  saved card.
- `refund(psp_reference:, amount_cents:)` — reverses a capture by its
  PaymentIntent, back to the card it came from; answers the `re_…` reference.

Test mode only for the PoC (`sk_test_…`).

### Test mode

Automated suites point the Stripe SDK at `stripe-mock`
(`Kiosk::TestHelpers::StripeMock` in `kiosk-test-support`) and take the same
path as production: the assistant calls `payment_setup`, which creates and maps
the Customer. stripe-mock lists a saved card for every Customer, so a later
`pay` charges it.
