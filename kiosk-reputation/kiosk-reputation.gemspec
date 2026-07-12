require_relative "lib/kiosk/reputation/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-reputation"
  spec.version       = Kiosk::Reputation::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Policy + wire-challenge layer for Kiosk's proof-of-work system"
  spec.description   = <<~DESC
    kiosk-reputation decides *when* and *how hard* to challenge a request with a
    proof-of-work, issues and verifies the signed wire challenge, and provides a
    pluggable reputation policy interface.

    Pure Ruby — no dependency on any PoW gem or kiosk-core. PoW backends register
    themselves via Kiosk::Reputation::Backends.register (kiosk-pow-equihash
    registers "equihash", the shipped default; kiosk-pow registers the legacy
    "argon2id"; a future kiosk-pow-cuckoo would register "cuckoo").

    Anti-DoS invariant: Challenge.verify performs cheap HMAC-sig + expiry checks
    BEFORE the one expensive backend eval, so floods of forged/expired proofs are
    rejected without running a proof check.

    Ships a configurable example policy (Policies::RateAndReputation) that, since
    Equihash has no continuous difficulty dial, escalates by PROOF COUNT (a
    count-curve) on high request rate, unproven principals, and bad-proof history.
    Providers are expected to replace or subclass it.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-reputation/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # base64 was a default gem through Ruby 3.3 but must be explicitly required
  # from Ruby 3.4+ (it became a bundled gem, no longer auto-loaded).
  spec.add_dependency "base64"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
