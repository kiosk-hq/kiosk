# kiosk-pay-stripe

Stripe PSP adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::PaymentProviders::Base` over Stripe PaymentIntents.

```ruby
require "kiosk/payment_providers/stripe"

Kiosk.configure do |c|
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key: ENV["STRIPE_SECRET_KEY"], # sk_test_… for the PoC
  )
end
```

Test mode only for the PoC; uses the `pm_card_visa` test payment method.
