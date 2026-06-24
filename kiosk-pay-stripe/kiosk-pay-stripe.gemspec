# frozen_string_literal: true

require_relative "lib/kiosk/payment_providers/stripe/version"

Gem::Specification.new do |spec|
  spec.name        = "kiosk-pay-stripe"
  spec.version     = Kiosk::PaymentProviders::StripeVersion::VERSION
  spec.authors     = ["Phil Pirozhkov"]
  spec.email       = ["phil@kiosk.tech"]

  spec.summary     = "Stripe PSP adapter for the Kiosk framework"
  spec.description = <<~DESC
    kiosk-pay-stripe is the open-source Stripe payment adapter for Kiosk.
    It implements Kiosk::PaymentProviders::Base (authorize / capture /
    refund) over Stripe PaymentIntents, settling AP2 cart mandates. Stripe
    is the default global OSS PSP; regional PSPs ship as separate gems.
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
