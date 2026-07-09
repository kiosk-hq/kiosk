require_relative "lib/kiosk/server/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-server"
  spec.version       = Kiosk::Server::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["phil@kiosk.tech"]

  spec.summary       = "Rails engine + Rack middleware + pure-Ruby helpers for the Kiosk framework"
  spec.description   = <<~DESC
    kiosk-server is the host-side surface for Kiosk: a Rails engine that
    mounts the wire endpoints (/kiosk/{schema,query,run,pay},
    /kiosk/auth/*, /kiosk/oauth/*), a Rack middleware that injects the
    Kiosk-Server-Version / Kiosk-API-Version / Kiosk-Min-Client response
    headers, a pure-Ruby builder for /.well-known/kiosk.json, and SQL
    generators for the four canonical schema migrations.

    Pre-v0.1: ships with the configuration surface, well-known doc
    builder, headers middleware, and schema migration SQL. Controllers
    (the Executor, OAuth surface, agent registration endpoints) land in
    follow-up releases.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-server/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.0"
  # JWT issue/verify for the §6.7 OAuth surface and §6.2 access tokens.
  # ruby-jwt is the de-facto Ruby JOSE library — small, MIT, no transitive deps.
  spec.add_dependency "jwt", "~> 2.8"

  spec.add_development_dependency "rspec",    "~> 3.13"
  spec.add_development_dependency "rake",     "~> 13.2"
  spec.add_development_dependency "rack",     "~> 3.0"
  # Needed by spec/generators — `Rails::Generators::Base` + Thor shell.
  # Host apps already have Rails loaded; we only require it for the
  # install-generator unit tests.
  spec.add_development_dependency "railties", "~> 8.1"
  # TestExecutor (lib/kiosk/server/test_executor.rb) implements the
  # Kiosk::TestHelpers::Journey contract; we need the error classes
  # at test time. Host apps depending on TestExecutor will have
  # kiosk-test-support loaded transitively via kiosk-rls-{rspec,minitest}.
  spec.add_development_dependency "kiosk-test-support", "~> 0.0"
end
