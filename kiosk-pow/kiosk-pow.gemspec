# frozen_string_literal: true

require_relative 'lib/kiosk/pow/version'

Gem::Specification.new do |spec|
  spec.name          = 'kiosk-pow'
  spec.version       = Kiosk::Pow::VERSION
  spec.authors       = ['Phil Pirozhkov']
  spec.email         = ['hello@fili.pp.ru']

  spec.summary       = 'The base of the Kiosk proof-of-work backends: BLAKE2b-256 and the backend contract'
  spec.description   = <<~DESC
    kiosk-pow is the base of every Kiosk proof-of-work backend:
    kiosk-pow-equihash (the shipped default), kiosk-pow-cuckoo and
    kiosk-pow-argon2id. It holds the one pure-Ruby BLAKE2b-256 that the
    backends hash with, and the reader for protocol parameters. Its README tells
    how to add a backend.

    Pure Ruby, no runtime dependencies. Does not depend on kiosk-core or Rails.
  DESC
  spec.homepage      = 'https://kiosk.tech'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/kiosk-hq/kiosk'
  spec.metadata['changelog_uri']   = 'https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pow/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/kiosk-hq/kiosk/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*') + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ['lib']
end
