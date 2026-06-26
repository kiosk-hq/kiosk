require_relative "lib/kiosk/pow/cuckoo/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-pow-cuckoo"
  spec.version       = Kiosk::Pow::Cuckoo::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["phil@kiosk.tech"]

  spec.summary       = "Cuckatoo-Cycle proof-of-work backend for Kiosk"
  spec.description   = <<~DESC
    kiosk-pow-cuckoo is an optional Cuckatoo-Cycle (Cuckoo Cycle variant)
    proof-of-work backend for the Kiosk framework.

    Ships the provider-side Ruby VERIFIER only (T1).  The verifier is cheap
    (μs range), security-critical, and validated against Grin's Cuckatoo29
    CI test vector.  A solver is a separate component (T2/T3).

    The implementation is clean-room from Tromp's public-domain algorithm
    spec (doc/spec, doc/mathspec) — no GPL/FAIR-MINING code is included.
    BLAKE2b-256 is pure Ruby from the public-domain BLAKE2 spec.
    SipHash-2-4 is pure Ruby from the public-domain SipHash spec with
    Cuckatoo's non-standard initialization (keys feed directly into v0..v3
    without XOR-ing the 0x736f6d65... magic constants).

    Does not depend on kiosk-core or Rails — pure Ruby, no native extensions.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pow-cuckoo/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files         = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # No runtime dependencies — pure Ruby, no native extensions.

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
