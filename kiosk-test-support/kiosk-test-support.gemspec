require_relative "lib/kiosk/test_helpers/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-test-support"
  spec.version       = Kiosk::TestHelpers::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Kiosk conformance checks and journey-test DSL for RSpec and Minitest"
  spec.description   = <<~DESC
    kiosk-test-support is the framework-agnostic test surface a Kiosk
    provider uses on their OWN application.

    It carries two things. The CONFORMANCE CHECKS assert the four
    properties the protocol makes normative of an origin: that its routes
    resolve, that a verb executes, that a query answers the shape it
    declared, and that data access is scoped to the authenticated
    principal. They ship with a Minitest adapter and an RSpec adapter, both
    loaded by explicit require, so the same fault reads identically in
    either framework.

    The JOURNEY DSL carries the identity-scoped call helpers
    (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`,
    `run_query`, `run_action`, `pay_action`, `kiosk_seed`), the pluggable
    executor contract, a NullExecutor for self-tests, and the structured
    error classes (`RLSDenied`, `QuotaExceeded`, `ExecutorNotConfigured`).
    It is wired into RSpec by `kiosk-rls-rspec` and into Minitest by
    `kiosk-rls-minitest`.

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

  spec.add_dependency "kiosk-core", "~> 0.5.0"

  # Both adapters are exercised by this gem's own suite — that a fault reads
  # identically through each is the whole claim of a framework-agnostic core,
  # and it is worth nothing unless something runs both. They stay DEVELOPMENT
  # dependencies: an adopter installs whichever framework they already use, and
  # requiring an adapter is what pulls that framework in.
  spec.add_development_dependency "minitest",     ">= 5", "< 7"
  spec.add_development_dependency "rspec",        "~> 3.13"
  spec.add_development_dependency "rake",         "~> 13.2"
  # The fallback schema validator, for an origin that does not bring its own.
  # An app running kiosk-server already has it as a runtime dependency and its
  # origin validates through the engine's checker instead.
  spec.add_development_dependency "json_schemer", ">= 2.0"
end
