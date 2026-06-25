require_relative "lib/kiosk/pow/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-pow"
  spec.version       = Kiosk::Pow::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["phil@kiosk.tech"]

  spec.summary       = "Argon2id memory-hard proof-of-work backend for Kiosk"
  spec.description   = <<~DESC
    kiosk-pow is the default PoW backend for the Kiosk framework: an Argon2id
    search-form proof-of-work that providers can demand on any verb to conserve
    their own compute against scraping and flooding.

    Ships the provider-side Ruby verify (one Argon2id eval, no loop) and a
    portable Python solver (solve.py / argon2-cffi) that an assistant runs in
    its sandbox when a `pow_required` challenge is received.  The Ruby verify
    and the Python solver produce byte-identical Argon2id digests — enforced
    by the included `rake parity` cross-implementation check.

    Used by kiosk-reputation (the policy layer) via the backend registry.
    Does not depend on kiosk-core or Rails — pure Ruby + libargon2 FFI.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pow/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[solve.py requirements.txt SKILL.md README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # Raw Argon2id FFI bindings — provides Argon2::Ext.argon2id_hash_raw.
  # We call the low-level FFI method directly to pass the exact KiB value for
  # m_cost (the high-level Password API uses a power-of-two exponent instead).
  spec.add_dependency "argon2", "~> 2.3"
  spec.add_dependency "ffi",    "~> 1.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
