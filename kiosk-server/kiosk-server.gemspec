require_relative "lib/kiosk/server/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-server"
  spec.version       = Kiosk::Server::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Rails engine + Rack middleware + pure-Ruby helpers for the Kiosk framework"
  spec.description   = <<~DESC
    kiosk-server is the host-side surface for Kiosk. The full surface ships:

      - The controllers — the per-verb wire (GET <endpoint>/<query-name>,
        POST <endpoint>/<action-name>) and the reserved endpoints
        (/kiosk/schema, /kiosk/pay), a derived OpenAPI description of both,
        the register/login proof-of-possession auth plane, JWKS, the KYC
        attestation endpoint, agents.txt / agents.json / kiosk.json
        discovery, and the account-binding ceremony (RFC 8628-shaped device
        authorization, the possession-proof-gated token poll, the verify and
        «Link an assistant» pages).
      - Kiosk::Server::Executor — dispatches a resolved command to the
        queries and actions the host registered.
      - Agent registration and login, with a pluggable agent-IdP.
      - The PoW gate that enforces a kiosk-reputation policy's challenge
        (soft dependency; zero overhead when no policy is set).
      - A Rack middleware injecting the Kiosk-Server-Version /
        Kiosk-API-Version / Kiosk-Min-Client response headers, a pure-Ruby
        builder for the discovery documents, SQL generators for the
        canonical schema migrations, and a `kiosk:install` generator that
        lays down the initializer and the migrations.

    The Rails engine serves that whole surface from one line — `mount
    Kiosk::Server::Engine => Kiosk.configuration.mount_path` — drawing the
    wire/auth/JWKS/KYC/binding routes under the mount and installing the
    root-relative discovery routes (agents.txt, .well-known) into the host
    when mounted; it also auto-injects the headers middleware. The operator
    draws only their own verbs, one explicit route each.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-server/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  # `app/` is NOT optional. Two controllers resolve their templates by path —
  # `append_view_path File.expand_path("../../../app/views", __dir__)` in
  # device_verify_controller.rb and assistants_controller.rb — so a gem
  # built without app/views answers BOTH HTML pages of the account-binding
  # ceremony with ActionView::MissingTemplate. It shipped that way because
  # every consumer in this monorepo uses `path:`, which serves the working
  # tree: no test here could have noticed, and only someone installing from
  # RubyGems would have. bin/check-gem-packaging is the standing guard.
  # `listen.py` rides along for the same reason `solve.py` does in
  # kiosk-pow-equihash: it is the pinned reference client for a wire this gem
  # serves, and {Kiosk::Server.listener_path} resolves it inside the INSTALLED
  # gem. Leaving it out makes that accessor answer a path that does not exist
  # everywhere but a checkout.
  spec.files = Dir.glob("app/**/*") + Dir.glob("lib/**/*") +
               %w[listen.py README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.5.0"
  # JWT issue/verify for the OAuth surface and access tokens.
  # ruby-jwt is the de-facto Ruby JOSE library — small, MIT, no transitive deps.
  spec.add_dependency "jwt", ">= 2.8", "< 4.0"
  # base64 was a default gem through Ruby 3.3 but became a BUNDLED gem in 3.4,
  # so it has to be declared. Required at load time by signing_key.rb,
  # result.rb and configuration_extension.rb; until now it arrived only by
  # accident, as a transitive dependency of jwt.
  spec.add_dependency "base64"
  # json_schemer — a RUNTIME dependency, not an optional extra.
  #
  # §8.1 item 5 makes coerce-then-validate an OPERATOR OBLIGATION: every
  # per-verb call is checked against the verb's declared `input_schema` before
  # the handler sees an argument, unconditionally. An origin that could not
  # load a JSON Schema validator could not serve a conformant wire at all,
  # so declaring it optional and failing on the first request would be an
  # install-time lie paid for at request time. `validate_responses` (the
  # development/CI output check) uses the same validator.
  #
  # «UNCONDITIONALLY» IS LITERAL AND IS NOT ABOUT THE TWO CONFIG FLAGS. The
  # obligation is enforced in `VerbController#arguments_for`, which calls
  # `RequestValidation.validate_arguments!` behind no flag at all, so a freshly
  # generated app carries it with an empty initializer — `validate_requests` is
  # the separate opt-in PoW-SHAPE check in front of the gate, and
  # `validate_responses` polices the OPERATOR's own output. Both are written by
  # `bin/rails g kiosk:install` as a starting posture; neither can switch the
  # sentence above off.
  #
  # It stays LAZILY REQUIRED in the code — the ConfigurationError naming the
  # gem is still there — because a host may vendor a checkout without it, and
  # a clear message beats a LoadError at boot.
  spec.add_dependency "json_schemer", ">= 2.3", "< 3.0"

  # ── Rails ──────────────────────────────────────────────────────────────
  # kiosk-server IS a Rails gem: it ships an engine, the wire/auth/discovery
  # controllers, an install generator and the canonical ActiveRecord migration
  # templates (lib/generators/kiosk/install/templates). Until
  # 2026-08-11 that dependency was undeclared and satisfied only by accident,
  # because every consumer happens to be a Rails app.
  #
  # We depend on the Rails components we actually reference, not on the
  # `rails` meta-gem: nothing here touches Action Mailer, Active Job, Active
  # Storage, Action Text or Action Mailbox, so requiring a host to install them
  # would be a false claim.
  #
  # **ACTION CABLE JOINED THAT LIST and the sentence above used to exclude it.** It is not an optional extra any more: the engine draws
  # a WebSocket route under the mount, so an operator who bundles this gem gets
  # Action Cable whether or not they ever declare a topic, exactly as they get
  # the `pay` route whether or not they configure a payment provider. Declaring
  # it is the honest reading of that; leaving it undeclared would be the same
  # accident the Rails dependency itself was until 2026-08-11 — satisfied only
  # because every consumer happens to be a Rails app.
  #
  # `~> 8.1` is the version the demos, the e2e fixture and CI actually run
  # (Rails 8.1.3 on Ruby 4.0.1). Older Rails lines are untested, so they are
  # not claimed; widening the floor means adding a CI matrix leg first.
  #
  # railties      — Kiosk::Server::Engine, Rails::Generators::{Base,Migration},
  #                 Rails.logger.
  spec.add_dependency "railties",      "~> 8.1"
  # actionpack    — ActionController::{API,Base,InvalidAuthenticityToken}.
  spec.add_dependency "actionpack",    "~> 8.1"
  # actioncable   — the event stream: ActionCable::Server::{Base,Configuration},
  #                 Connection::Base and Channel::Base, mounted at
  #                 `<endpoint>/events`. The engine builds its OWN server rather
  #                 than using `ActionCable.server`, so a host that already runs
  #                 channels of its own keeps its connection class and its
  #                 forgery protection untouched.
  spec.add_dependency "actioncable",   "~> 8.1"
  # activerecord  — ActiveRecord::Base.lease_connection is how the auth plane,
  #                 the wire and the durable stores reach the database (NOT
  #                 `.connection`, which Rails 8.1 soft-deprecates and which
  #                 RAISES under permanent_connection_checkout = :disallowed),
  #                 plus ActiveRecord::{RecordNotUnique,StatementInvalid,Migration}.
  spec.add_dependency "activerecord",  "~> 8.1"
  # activesupport — String#constantize (agent_registration) and String#classify
  #                 (generator template).
  spec.add_dependency "activesupport", "~> 8.1"

  spec.add_development_dependency "rspec",    "~> 3.13"
  spec.add_development_dependency "rake",     "~> 13.2"
  spec.add_development_dependency "rack",     "~> 3.0"
  # puma — the events socket cannot be exercised without a server that supports
  # `rack.hijack`: Action Cable's connection takes the socket away from Rack,
  # and a handler that cannot give it up answers the upgrade with an ordinary
  # HTTP response. So the one spec that drives a real WebSocket boots Puma in a
  # subprocess. Development only; nothing at runtime depends on a server.
  spec.add_development_dependency "puma",     "~> 6.0"
  # TestExecutor (lib/kiosk/server/test_executor.rb) implements the
  # Kiosk::TestHelpers::Journey contract; we need the error classes
  # at test time. Host apps depending on TestExecutor will have
  # kiosk-test-support loaded transitively via kiosk-rls-{rspec,minitest}.
  spec.add_development_dependency "kiosk-test-support", "~> 0.5.0"
end
