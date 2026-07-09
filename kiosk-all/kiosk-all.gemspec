require_relative "lib/kiosk/all/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-all"
  spec.version       = Kiosk::All::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Meta-gem that bundles the Kiosk production stack (core + server)"
  spec.description   = <<~DESC
    kiosk-all is the «I just want to start» entry point for the Kiosk
    framework. Installing it pulls in the production data-plane gems:
    kiosk-core (value types, abstract bases, configuration) and
    kiosk-server (Rails engine, headers, well-known, schema migrations).

    Deliberately out of scope:
      - kiosk-rls — opt-in DB-level RLS defense-in-depth; add it
        explicitly if you use enable_rls_on in migrations.
      - Test harnesses (kiosk-test-support, kiosk-rls-rspec,
        kiosk-rls-minitest) — host picks one per stack and adds it to
        the dev/test group of its Gemfile.
      - Adapter gems (kiosk-user-idp-*, kiosk-pay-*,
        kiosk-credentials-*) — providers pick per market/stack.

    See https://kiosk.tech and design spec §15.4.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-all/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core",   "~> 0.0"
  spec.add_dependency "kiosk-server", "~> 0.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
