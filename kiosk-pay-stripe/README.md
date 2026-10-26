# kiosk-pay-stripe

Stripe PSP adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::PaymentProviders::Base` over Stripe PaymentIntents.

## Install

There is no default PSP — `Kiosk::Configuration#payment_provider` starts `nil`
— and neither `kiosk-server` nor `kiosk-all` pulls an adapter in, so taking
payments means adding this one yourself:

```ruby
gem "kiosk-pay-stripe"
```

Bundler brings the three runtime dependencies with it: `activerecord`,
`kiosk-core` and Stripe's own `stripe` gem. In a Rails app `Bundler.require`
loads the adapter. The adapter does nothing until you assign it to
`payment_provider`, as the block below shows.

You also need a secret key for the **operator's own** Stripe account. The
adapter does not check whether the key is a test-mode key (`sk_test_…`) or a
live one; the demos use test mode. The buyer's card is saved on that account,
so there is no Kiosk-side Stripe account to configure.

## Model: card-on-file + off_session (SetupIntent)

The headline flow saves the buyer's card ONCE on the *operator's* Stripe
account as a Customer + PaymentMethod (keyed to the customer's `user_id`).
Subsequent purchases are charged `off_session` (initiated by the operator)
against that saved card — the assistant authorizes,
never presents a card.

The `user_id → Stripe Customer` mapping lives in the host's `kiosk_stripe_customers`
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
    api_key: ENV.fetch("STRIPE_SECRET_KEY"),
  )
end
```

An app that already keeps the mapping elsewhere passes `customer_resolver:
->(user_id) { … }` and `customer_saver: ->(user_id, cus_id) { … }` instead.

The saver replaces any earlier mapping for the customer: when Stripe no
longer has the mapped Customer (deleted, or from another account), the adapter
treats the customer as having no saved card and saves a fresh Customer.

Card-setup handshake (see the Payment section of the spec):

- `setup_required?(user_id:)` — true when the customer must set up a card
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
  "did not find out", so it mints a fresh session (the readiness check keeps answering)
  and warns that the url is not stable until that clears.
- `setup_return_user_id(params)` — the customer whose Checkout Session the
  return page's `session_id` names, asked of Stripe; kiosk-server then pushes the
  `payment_setup` event once `setup_required?` answers false.
- `saved_method?(user_id:)` — true once the resolved Customer has a usable
  saved card.
- `refund(psp_reference:, amount_cents:, key:)` — reverses a capture by its
  PaymentIntent, back to the card it came from; answers the `re_…` reference.
  The Stripe request is keyed by the charge and `key`, so each refund of one
  charge is its own, and a retry with the same key refunds once.

### Test mode

Automated suites point the Stripe SDK at `stripe-mock`
(`Kiosk::TestHelpers::StripeMock` in `kiosk-test-support`) and take the same
path as production: the assistant calls `payment_setup`, which creates and maps
the Customer. stripe-mock lists a saved card for every Customer, so a later
`pay` charges it.
