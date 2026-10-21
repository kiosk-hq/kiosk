# frozen_string_literal: true

require_relative 'lib/kiosk/server/version'

Gem::Specification.new do |spec|
  spec.name          = 'kiosk-server'
  spec.version       = Kiosk::Server::VERSION
  spec.authors       = ['Phil Pirozhkov']
  spec.email         = ['hello@fili.pp.ru']

  spec.summary       = 'Rails engine + Rack middleware + pure-Ruby helpers for the Kiosk framework'
  spec.description   = <<~DESC
    kiosk-server is the host-side surface for Kiosk. The full surface ships:

      - The controllers — the per-verb wire (GET <endpoint>/<query-name>,
        POST <endpoint>/<action-name>) and the reserved endpoints
        (/kiosk/schema, /kiosk/pay), a derived OpenAPI description of both,
        OAuth client registration (RFC 7591) and the token endpoint
        (private_key_jwt client assertions, DPoP), JWKS, the KYC
        attestation endpoint, agents.txt / agents.json / kiosk.json
        discovery, and the account-binding ceremony (RFC 8628 device
        authorization and token poll, the verify and «Link an assistant»
        pages).
      - Kiosk::Server::Executor — dispatches a resolved command to the
        queries and actions the host registered.
      - Client registration and authentication, with a pluggable agent-IdP.
      - The PoW gate that enforces a kiosk-reputation policy's challenge
        (soft dependency; zero overhead when no policy is set).
      - A Rack middleware injecting the Kiosk-Server-Version /
        Kiosk-API-Version / Kiosk-Min-Client response headers, a pure-Ruby
        builder for the discovery documents, SQL generators for the
        canonical schema migrations, and a `kiosk:install` generator that
        lays down the initializer and the migrations.

    The Rails engine serves that whole surface from one `kiosk` block in
    config/routes.rb, which mounts it at Kiosk.configuration.mount_path —
    drawing the wire/auth/JWKS/KYC/binding routes under the mount and
    installing the root-relative discovery routes (agents.txt, .well-known)
    into the host — then one route per query and action the block names. It
    also auto-injects the headers middleware.
  DESC
  spec.homepage      = 'https://kiosk.tech'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['homepage_uri']     = spec.homepage
  spec.metadata['source_code_uri']  = 'https://github.com/kiosk-hq/kiosk'
  spec.metadata['changelog_uri']    = 'https://github.com/kiosk-hq/kiosk/blob/main/kiosk-server/CHANGELOG.md'
  spec.metadata['bug_tracker_uri']  = 'https://github.com/kiosk-hq/kiosk/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # `app/` holds the controllers, the events channel, the models and the
  # binding ceremony's views.
  # `listen.py` is the pinned reference client for the event stream;
  # `requirements.txt` beside it declares its python dependency.
  spec.files = Dir.glob('app/**/*') + Dir.glob('lib/**/*') +
               %w[listen.py requirements.txt README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'kiosk-core', '~> 0.5.0'
  # Access tokens and the OAuth surface.
  spec.add_dependency 'jwt', '>= 2.8', '< 4.0'
  # A bundled gem since Ruby 3.4; signing_key.rb and configuration_extension.rb require it.
  spec.add_dependency 'base64'
  # Loads the files under lib/kiosk.
  spec.add_dependency 'zeitwerk', '~> 2.6'
  # Every verb call is validated against its `input_schema`; `validate_responses` uses it too.
  spec.add_dependency 'json_schemer', '>= 2.3', '< 3.0'

  # The Rails components the engine uses; `~> 8.1` is what CI runs.
  # railties: the engine, the install generator, Rails.logger.
  spec.add_dependency 'railties',      '~> 8.1'
  # actionpack: the wire, auth and discovery controllers.
  spec.add_dependency 'actionpack',    '~> 8.1'
  # actioncable: the event stream at `<endpoint>/events`, on the engine's own server.
  spec.add_dependency 'actioncable',   '~> 8.1'
  # activerecord: the durable stores and the engine's models.
  spec.add_dependency 'activerecord',  '~> 8.1'
  # activesupport: the core extensions the code uses.
  spec.add_dependency 'activesupport', '~> 8.1'
end
