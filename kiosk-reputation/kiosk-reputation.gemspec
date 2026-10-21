# frozen_string_literal: true

require_relative 'lib/kiosk/reputation/version'

Gem::Specification.new do |spec|
  spec.name          = 'kiosk-reputation'
  spec.version       = Kiosk::Reputation::VERSION
  spec.authors       = ['Phil Pirozhkov']
  spec.email         = ['hello@fili.pp.ru']

  spec.summary       = "Policy + challenge layer for Kiosk's proof-of-work system"
  spec.description   = <<~DESC
    kiosk-reputation decides *when* and *how hard* to challenge a request with a
    proof-of-work, issues and verifies the signed challenge, and provides a
    pluggable reputation policy interface.

    Pure Ruby — no dependency on any PoW gem or kiosk-core. A PoW backend is
    registered via Kiosk::Reputation::Backends.register: kiosk-pow-equihash
    registers itself as "equihash" (the shipped default) in a Rails app; the host
    registers kiosk-pow-argon2id as the legacy "argon2id" and kiosk-pow-cuckoo as
    the opt-in "cuckatoo".

    Anti-DoS invariant: Challenge.verify performs cheap HMAC-sig + expiry checks
    BEFORE the one expensive backend eval, so floods of forged/expired proofs are
    rejected without running a proof check.

    Ships one policy, Policies::RecentSpend: it asks one proof of a session,
    by a chance that the customer's recent spend lowers.
  DESC
  spec.homepage      = 'https://kiosk.tech'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/kiosk-hq/kiosk'
  spec.metadata['changelog_uri']   = 'https://github.com/kiosk-hq/kiosk/blob/main/kiosk-reputation/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/kiosk-hq/kiosk/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*') + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ['lib']

  # A bundled gem since Ruby 3.4.
  spec.add_dependency 'base64'
end
