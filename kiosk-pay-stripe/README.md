# kiosk-pay-stripe

Stripe PSP adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::PaymentProviders::Base` over Stripe PaymentIntents.

## Model: card-on-file + off_session (SetupIntent)

The headline flow saves the buyer's card ONCE on the *provider's* Stripe
account as a Customer + PaymentMethod (keyed to the synthetic principal /
`user_id`). Subsequent purchases are charged `off_session`
(merchant-initiated) against that saved card — the assistant authorizes,
never presents a card.

The gem stays provider-agnostic: the `principal → Stripe Customer` mapping is
injected by the host app via `customer_resolver:` and `customer_saver:`
callables. No app table is touched inside this gem.

```ruby
require "kiosk/payment_providers/stripe"

Kiosk.configure do |c|
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key:           ENV["STRIPE_SECRET_KEY"], # sk_test_… for the PoC
    customer_resolver: ->(user_id) { store.customer_id_for(user_id) },
    customer_saver:    ->(user_id, cus_id) { store.save(user_id, cus_id) },
    return_url:        "https://provider.example/payment/return",
  )
end
```

Card-setup handshake (see the Payment section of the spec):

- `setup_required?(user_id:)` — true when the principal must set up a card
  before a charge can proceed.
- `setup_url(user_id:)` — hosted Stripe Checkout URL (`mode: "setup"`). The
  human opens it in a browser (NOT the chat) to enter their card on Stripe's
  hosted page; the human is redirected to `return_url` afterward. The gem
  never sees card data. **Stable across polls:** an already-outstanding
  (`status: open`, same `return_url`) setup session is reused, so an assistant
  polling readiness keeps handing its human the SAME link instead of a fresh
  one per poll.
- `saved_method?(user_id:)` — true once the resolved Customer has a usable
  saved card.

Test mode only for the PoC (`sk_test_…`).

### Back-compat / test fallback

When no `customer_resolver` is configured, the adapter runs in a back-compat
mode: `capture` uses an explicitly presented `payment_method:` or, absent
that, the `test_payment_method` (default `pm_card_visa`) — no SetupIntent,
no card-on-file. Set `test_payment_method: nil` to disable the fallback.

For automated suites, `test_autocard: true` + `attach_test_card` simulate a
completed SetupIntent (auto-attaching a test card at capture) so drivers need
no hosted card-entry step. Never enable `test_autocard` in production or the
live demo.
