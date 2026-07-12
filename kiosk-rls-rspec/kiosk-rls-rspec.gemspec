require_relative "lib/kiosk/rls_rspec/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-rls-rspec"
  spec.version       = Kiosk::RLSRSpec::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "RSpec integration for the Kiosk journey-test DSL"
  spec.description   = <<~DESC
    kiosk-rls-rspec wires the framework-agnostic Kiosk journey-test DSL
    (kiosk-test-support) into RSpec.

    Automatically mixes the journey helpers (`as_agent_of`, `as_user`,
    `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`,
    `kiosk_seed`) into any example group tagged
    `type: :kiosk_journey` (or `type: :kiosk_agent`, which `kiosk-agent-test`
    later upgrades to live-LLM mode).

    Ships the matchers `be_rls_denied` and `be_quota_exceeded` for asserting
    the structured exit-code errors.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-rls-rspec/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core",         "~> 0.0"
  spec.add_dependency "kiosk-rls",          "~> 0.0"
  spec.add_dependency "kiosk-test-support", "~> 0.0"
  spec.add_dependency "rspec",              "~> 3.13"

  spec.add_development_dependency "rake",  "~> 13.2"
end
