require_relative "lib/kiosk/test_helpers/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-test-support"
  spec.version       = Kiosk::TestHelpers::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Shared journey-test DSL for Kiosk test harnesses (RSpec, Minitest)"
  spec.description   = <<~DESC
    kiosk-test-support carries the framework-agnostic pieces of the Kiosk
    journey-test DSL described in design spec §12: the Journey module
    (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`,
    `run_action`, `pay_action`, `kiosk_seed`), the pluggable executor
    contract, a NullExecutor for self-tests, and the structured error
    classes (`RLSDenied`, `QuotaExceeded`, `ExecutorNotConfigured`).

    Wired into RSpec by `kiosk-rls-rspec` and into Minitest by
    `kiosk-rls-minitest`. Providers normally install one of those two —
    this gem is a transitive dependency.

    No Postgres, no Rails, no test-framework dependency. The actual
    Executor (which runs SQL with the right GUCs) is provided by
    `kiosk-server` at runtime via `Kiosk::TestHelpers.executor=`.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-test-support/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.0"
  spec.add_dependency "kiosk-rls",  "~> 0.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
