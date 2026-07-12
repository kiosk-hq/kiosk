require_relative "lib/kiosk/rls/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-rls"
  spec.version       = Kiosk::RLS::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "RLS DSL and PostgreSQL DDL emitter for the Kiosk framework"
  spec.description   = <<~DESC
    kiosk-rls provides the row-level-security DSL Kiosk providers use inside
    their ActiveRecord migrations: `enable_rls_on`, `policy`, plus the
    add/change/remove/rename migration verbs.

    The DSL compiles to standard PostgreSQL DDL (ALTER TABLE ENABLE ROW
    LEVEL SECURITY, GRANT, CREATE POLICY, COMMENT ON TABLE) and runs inside
    the migration's transaction via the host's `#execute` method.

    Adds RLS-relevant fields to `Kiosk::Configuration`: `app_role`,
    `system_role`, `schema`.

    No PostgreSQL runtime dependency — pure SQL generation. The host
    provides the connection.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-rls/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
