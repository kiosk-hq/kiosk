# frozen_string_literal: true

require_relative "lib/kiosk/payment_providers/stripe/version"

Gem::Specification.new do |spec|
  spec.name        = "kiosk-pay-stripe"
  spec.version     = Kiosk::PaymentProviders::StripeVersion::VERSION
  spec.authors     = ["Phil Pirozhkov"]
  spec.email       = ["hello@fili.pp.ru"]

  spec.summary     = "Stripe PSP adapter for the Kiosk framework"
  spec.description = <<~DESC
    kiosk-pay-stripe is the open-source Stripe payment adapter for Kiosk. It
    implements both halves of the provider-acquired, card-on-file model:

      - Card acquisition. `setup_url(user_id:)` returns a hosted Stripe
        Checkout session in `mode: "setup"` that saves the buyer's card on the
        PROVIDER's own Stripe account (an existing open setup session is
        reused, so the url is stable across polls); `setup_required?` tells the
        wire whether a principal still has to complete it, backed by
        `saved_method?`, which asks Stripe whether the resolved Customer has a
        usable card.
      - Charging. `Kiosk::PaymentProviders::Base#capture` settles an AP2 cart
        mandate as an `off_session` (merchant-initiated) PaymentIntent against
        that saved card — the assistant authorizes the cart, it never presents
        a card.

    The gem stays app-agnostic: the principal-to-Stripe-Customer mapping is
    injected by the host through `customer_resolver:` / `customer_saver:`
    callables, and no application table is read inside the gem.

    Today only kiosk-pay-stripe ships; there is no default PSP
    (Configuration#payment_provider is nil). Further open adapters (e.g.
    Paddle) and commercial regional PSPs are planned on customer demand —
    none exist yet.
  DESC
  spec.homepage    = "https://kiosk.tech"
  spec.license     = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pay-stripe/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.0"
  spec.add_dependency "stripe", "~> 19"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
