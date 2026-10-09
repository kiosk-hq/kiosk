require_relative "lib/kiosk/redteam/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-redteam"
  spec.version       = Kiosk::Redteam::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Adversarial regression harness for Kiosk providers"
  spec.description   = <<~DESC
    kiosk-redteam drives hostile HTTP scenarios against any Kiosk provider
    and asserts each attack is correctly blocked — a deliberate refusal, never
    a crash and never a toll the harness could not settle.  A scenario that
    finds a real breach fails loudly.

    Ships a Scenario/Verdict/Runner framework and a library of generic attack
    scenarios parameterised by a per-provider Profile. It attacks through the
    assistant client kiosk-test-support ships.

    No dependency on Rails.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-redteam/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files         = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-test-support", "~> 0.5.0"
  spec.add_dependency "base64"

  spec.add_development_dependency "rspec",   "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "rake",    "~> 13.2"
end
