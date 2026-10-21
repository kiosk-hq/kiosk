# frozen_string_literal: true

require_relative 'lib/kiosk/test_helpers/version'

Gem::Specification.new do |spec|
  spec.name          = 'kiosk-test-support'
  spec.version       = Kiosk::TestHelpers::VERSION
  spec.authors       = ['Phil Pirozhkov']
  spec.email         = ['hello@fili.pp.ru']

  spec.summary       = 'Kiosk conformance checks and journey-test DSL for RSpec and Minitest'
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

    The ASSISTANT drives an origin over HTTP as an assistant does: it
    registers, pays proof-of-work tolls, queries, runs, pays with signed
    mandates and listens on the event stream. `Kyc` stands in for the
    operator's KYC provider, and `StripeMock` fronts a local stripe-mock.

    `InProcessExecutor`, `InProcessWire` and `Conformance::InProcessOrigin`
    run against kiosk-server, and `Person` signs in through
    kiosk-user-idp-devise; both are dependencies. The host's bundle brings
    the rest: the Minitest and RSpec adapters use the test framework the
    host runs, `LiveServer` serves the app with Puma, and `Wire` solves
    Equihash tolls with kiosk-pow-equihash.
  DESC
  spec.homepage      = 'https://kiosk.tech'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['homepage_uri']     = spec.homepage
  spec.metadata['source_code_uri']  = 'https://github.com/kiosk-hq/kiosk'
  spec.metadata['changelog_uri']    = 'https://github.com/kiosk-hq/kiosk/blob/main/kiosk-test-support/CHANGELOG.md'
  spec.metadata['bug_tracker_uri']  = 'https://github.com/kiosk-hq/kiosk/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*') + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'json_schemer', '>= 2.3', '< 3.0'
  spec.add_dependency 'jwt', '>= 2.10', '< 4.0'
  spec.add_dependency 'kiosk-core', '~> 0.6.0'
  spec.add_dependency 'kiosk-server', '~> 0.6.0'
  spec.add_dependency 'kiosk-user-idp-devise', '~> 0.6.0'
  spec.add_dependency 'websocket-driver', '~> 0.7'
end
