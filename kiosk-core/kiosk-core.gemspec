require_relative "lib/kiosk/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-core"
  spec.version       = Kiosk::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Core abstractions for Kiosk — value types, abstract bases, GUC constants, configuration"
  spec.description   = <<~DESC
    kiosk-core is the foundation for the Kiosk framework. It defines the value
    types (Identity, Mandate), the abstract base classes adapters extend
    (AgentIdentityProviders, UserIdentityProviders, PaymentProviders), the
    Postgres GUC namespace constants, the protocol-version surface, and the
    Kiosk.configure block.

    No Rails dependency. Loadable in any Ruby app; the heavier kiosk-server
    and kiosk-rls gems build on top of this.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk-core"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk-core/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk-core/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
