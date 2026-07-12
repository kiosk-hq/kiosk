require_relative "lib/kiosk/rls_minitest/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-rls-minitest"
  spec.version       = Kiosk::RLSMinitest::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Minitest integration for the Kiosk journey-test DSL"
  spec.description   = <<~DESC
    kiosk-rls-minitest wires the framework-agnostic Kiosk journey-test DSL
    (kiosk-test-support) into Minitest.

    `include Kiosk::TestHelpers` inside any `Minitest::Test` subclass mixes
    in the journey helpers (`as_agent_of`, `as_user`, `as_agent`,
    `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`).

    Ships the assertions `assert_rls_denied` and `assert_quota_exceeded`
    for asserting the structured exit-code errors — both also exposed as
    the Minitest `_must_*` / `_wont_*` spec-DSL forms.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-rls-minitest/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core",         "~> 0.0"
  spec.add_dependency "kiosk-rls",          "~> 0.0"
  spec.add_dependency "kiosk-test-support", "~> 0.0"
  spec.add_dependency "minitest",           "~> 5.0"

  spec.add_development_dependency "rake", "~> 13.2"
end
