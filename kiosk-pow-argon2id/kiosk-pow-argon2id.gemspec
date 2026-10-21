# frozen_string_literal: true

require_relative 'lib/kiosk/pow/argon2id/version'

Gem::Specification.new do |spec|
  spec.name          = 'kiosk-pow-argon2id'
  spec.version       = Kiosk::Pow::Argon2id::VERSION
  spec.authors       = ['Phil Pirozhkov']
  spec.email         = ['hello@fili.pp.ru']

  spec.summary       = 'Argon2id memory-hard proof-of-work backend for Kiosk (legacy)'
  spec.description   = <<~DESC
    kiosk-pow-argon2id is the legacy proof-of-work backend for the Kiosk
    framework: an Argon2id search-form proof of work. The shipped default is
    Equihash (kiosk-pow-equihash). Argon2id stays a legacy backend because its
    64 MiB verify is too expensive for a gateway.

    Ships the operator-side Ruby verify (one Argon2id evaluation, no loop) and
    a Python solver (solve.py, argon2-cffi). The Ruby verify and the Python
    solver produce byte-identical Argon2id digests. The gem's `:parity` spec
    examples check this, and so does the `rake parity` task. Neither the
    Rakefile nor spec/ is in the package.

    Built on kiosk-pow. kiosk-reputation reaches it when a host registers it
    under "argon2id"; it does not register itself. Does not depend on
    kiosk-core or Rails: pure Ruby and libargon2 through FFI.
  DESC
  spec.homepage      = 'https://kiosk.tech'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/kiosk-hq/kiosk'
  spec.metadata['changelog_uri']   = 'https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pow-argon2id/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/kiosk-hq/kiosk/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*') + %w[solve.py requirements.txt README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ['lib']

  # Raw Argon2id FFI bindings — provides Argon2::Ext.argon2id_hash_raw.
  # We call the low-level FFI method directly to pass the exact KiB value for
  # m_cost (the high-level Password API uses a power-of-two exponent instead).
  spec.add_dependency 'argon2',    '~> 2.3'
  spec.add_dependency 'ffi',       '~> 1.0'
  spec.add_dependency 'kiosk-pow', '~> 0.6.0'
end
