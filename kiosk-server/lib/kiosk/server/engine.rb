# frozen_string_literal: true

# The Rails engine. `mount Kiosk::Server::Engine => Kiosk.configuration.mount_path`
# draws the protocol plane under the mount and appends the discovery documents
# to the host's root routes. The operator routes its own verbs.
#
# `rails` first: rails/engine leans on ActiveSupport core_ext that only the
# top-level entry point loads.
require "rails"
require "rails/engine"

module Kiosk
  module Server
    class Engine < ::Rails::Engine
      isolate_namespace Kiosk::Server

      # True when this engine is mounted anywhere in +route_set+. Used by the
      # root-discovery initializer below to keep the gem inert-by-default;
      # public so a host can ask the same question (e.g. in a smoke test).
      # Journey stores a mounted rack endpoint wrapped in a Constraints
      # object whose #app is whatever `mount` was given — this engine CLASS
      # in the documented one-liner, or its instance.
      def self.mounted_in?(route_set)
        route_set.routes.any? do |route|
          app = route.app
          app.respond_to?(:app) && (app.app == self || app.app.is_a?(self))
        end
      end

      # Auto-injects HeadersMiddleware into the host app's stack, OUTSIDE the
      # exception renderers.
      #
      # NOT `app.middleware.use`, which APPENDS — the innermost middleware,
      # directly above the router. That puts every response Rails composes
      # FROM AN EXCEPTION outside the stamp, and §3.6 makes the three version
      # headers mandatory on "every response served under the operator's
      # mount path … on success and on error alike". MEASURED on a booted demo
      # with the middleware appended: `POST /kiosk/agents/kyc` on an app that
      # does not draw that route answered a 404 with none of the three, while
      # the same origin's `POST /kiosk/auth/login` 400 carried all three —
      # because a routing 404 never returns THROUGH an appended middleware, it
      # is manufactured above it. An unhandled 500 has the same shape. Those are
      # precisely the responses a mis-versioned client is most likely to get:
      # the handshake exists so a client can decide whether it can speak to
      # this origin at all, and a 404 for a path its version expects to exist
      # is the first thing it sees.
      #
      # WHY `ActionDispatch::ShowExceptions` IS THE ANCHOR, and not another.
      # It is the OUTERMOST middleware in Rails' stack that manufactures a
      # response out of an exception: `DebugExceptions` (the development
      # diagnostic page) and `ActionableExceptions` sit INSIDE it, and the
      # `exceptions_app` that renders `public/404.html` / `public/500.html` in
      # production is called BY it. Insert immediately outside it and every
      # response the application produces — rendered by a controller, by
      # DebugExceptions, or by ShowExceptions' own exceptions_app — passes
      # back out through the stamp. Nothing between it and the router can
      # bypass it, which is the property that matters: the headers are not
      # "applied on more paths", they are applied where the stack converges.
      #
      # NOT position 0. The layers ABOVE ShowExceptions — `HostAuthorization`
      # (a 403 for a `Host` this origin does not answer to), `SSL` (the
      # http→https redirect), `Sendfile`, `Static` — answer BEFORE the
      # application is reached at all; a request rejected for naming the wrong
      # origin is not a response this operator's mount served. Staying below
      # them also keeps this middleware inside `ActionDispatch::Executor`,
      # where every other application middleware runs.
      #
      # NOT `use` with a wider rescue either: rescuing more exceptions inside
      # the engine would patch paths one at a time and still miss the routing
      # 404, which raises before any Kiosk code runs.
      #
      # A host that DELETES `ActionDispatch::ShowExceptions` from its stack
      # will fail this insert at boot with Rails' own "No such middleware"
      # error. That is the honest failure: on such a stack there is no layer
      # that renders exceptions, so there is nothing to wrap and the operator
      # has to place this middleware themselves.
      initializer "kiosk-server.middleware" do |app|
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::HeadersMiddleware
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::IssuerMiddleware
      end

      # The wire's credential-bearing request fields, kept out of the host's
      # `Parameters:` log line: the possession proof (§5.2), the link code
      # (§6.2), the device code (§6.1), the KYC attestation (§12) and the
      # three payment mandates (§11).
      #
      # Whole keys rather than Rails' default substring match, so an
      # operator's own `promo_code` is left alone. `public_key` is not here —
      # §5: a public key is not a credential, it is public — and neither is
      # the proof-of-work proof, which is not a secret and rides in the
      # `Kiosk-PoW` request header rather than in a parameter.
      FILTERED_PARAMETERS = %w[
        signed code device_code kyc_jws
        intent_mandate_jws cart_mandate_jws payment_mandate_jws
      ].map { |field| /\A#{field}\z/ }.freeze

      initializer "kiosk-server.filter_parameters" do |app|
        app.config.filter_parameters += FILTERED_PARAMETERS
      end

      # Rebuilds the registries at boot and after every development reload.
      config.to_prepare do
        Kiosk::Server::SchemaSlots.reset!
        Kiosk::Server::HandlerRegistrations.reload!
        Kiosk::Server::SchemaDocument.reset!
        Kiosk::Server::OpenApi.reset!
      end

      # Derives the `schema` catalog after eager loading, in every environment.
      config.after_initialize do
        Kiosk::Server::SchemaDocument.derive!
      end

      config.after_initialize do
        next unless Kiosk::Server::Actions.known.empty? && Kiosk::Server::Queries.known.empty?

        message = "[kiosk-server] no queries or actions are registered. Put handler controllers " \
                  "(classes including Kiosk::Handler) in #{Kiosk::Server::HandlerRegistrations::HANDLERS_DIR}."
        ::Rails.logger ? ::Rails.logger.warn(message) : warn(message)
      end

      # ── A WRONG `issuer` IS A SILENT AUTH OUTAGE ───────────────────────────
      #
      # Every assistant's proof is refused with "proof audience mismatch" while
      # the app looks healthy. Warned, not raised: an operator installs and
      # seeds before the public origin exists. Unset is wrong everywhere; a
      # loopback served origin only outside development and test.
      #
      # @param config [Kiosk::Configuration] normally `Kiosk.configuration`
      # @param local [Boolean] normally `Rails.env.local?`
      # @return [String, nil]
      LOOPBACK_ISSUER =
        %r{\A(?:https?://)?(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\])(?::\d+)?/?\z}i

      def self.issuer_warning(config:, local:)
        issuer = config.issuer.to_s.strip

        if issuer.empty?
          return "[kiosk-server] `c.issuer` is not set, so every authenticated request is refused " \
                 "with \"proof audience mismatch\". Set it to the origin assistants dial: " \
                 "Kiosk.configure { |c| c.issuer = \"https://api.example.com\" }."
        end

        return nil if local

        loopback = [issuer, *config.additional_origins].map { |o| o.to_s.strip }
                                                        .find { |o| LOOPBACK_ISSUER.match?(o) }
        return nil unless loopback

        "[kiosk-server] The served origin #{loopback.inspect} is a loopback origin outside " \
          "development and test; no assistant can reach it, so every authenticated request is " \
          "refused with \"proof audience mismatch\". Set `c.issuer` to the public origin and " \
          "list a second business in `c.additional_origins`."
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.issuer_warning(
          config: Kiosk.configuration, local: ::Rails.env.local?,
        )
        next unless message

        ::Rails.logger ? ::Rails.logger.warn(message) : warn(message)
      end

      # ── THERE IS ALWAYS A DEFAULT ROLE ────────────────────────────────────
      #
      # `registration_role` is what every role resolution in this engine falls
      # back to: {AccountBinding.bind!} applies it on both branches when the
      # ceremony carries no role, and {AgentRegistration} pins it on a
      # self-registration, which has no human in it at all. An origin that
      # declares a role vocabulary and configures no default has nowhere for
      # those to land — every such assistant gets the EMPTY role set and a token
      # with no `role` claim, while the origin's own verbs branch on one. So the
      # engine refuses to start on that configuration, naming the setting.
      #
      # THE REQUIREMENT IS CONDITIONAL, AND THAT IS THE WHOLE OF IT. An origin
      # that declares NO roles is untouched: it configures no default, no
      # binding carries a role, its tokens omit the `role` claim, and it boots
      # exactly as before. Both shapes are total; the MIXTURE is what is
      # refused, which is the contract kiosk.tech `protocol.md` Section 6.3
      # already states for the ceremony, applied to the one path that has no
      # human in it.
      #
      # WHY AT BOOT RATHER THAN AT THE CEREMONY, where the OTHER half of the
      # same contract is only warned about (see
      # {AccountBinding.warn_role_resolution_not_total}). That half asks whether
      # the HOST's `#kiosk_role` is total over the host's users table, which no
      # configuration file can answer, so a boot check there would accuse every
      # multi-role origin or none. This one reads two settings out of the
      # operator's own initializer and is settled before a request exists.
      #
      # IT RAISES rather than warns, on the `signing_key` precedent: a fact
      # settled at boot whose silent wrong answer is invisible afterwards —
      # assistants that quietly cannot act, with nothing in the operator's logs
      # or metrics to say why. The condition is a class method so it is
      # unit-testable without booting an application.
      # Returns the message, or nil when this origin has nothing to answer for.
      #
      # @param config [Kiosk::Configuration] normally `Kiosk.configuration`
      # @return [String, nil]
      def self.default_role_configuration_error(config:)
        declared = Array(config.roles).map(&:to_s).reject(&:empty?)
        return nil if declared.empty?

        configured = config.registration_role.to_s.strip
        return nil if declared.include?(configured)

        head =
          if configured.empty?
            "[kiosk-server] this origin declares roles (#{declared.join(', ')}) and configures no " \
              "`registration_role`."
          else
            "[kiosk-server] this origin declares roles (#{declared.join(', ')}) and its " \
              "`registration_role` is #{config.registration_role.inspect}, which is not one of them."
          end

        "#{head} There is always a default role: an AI assistant admitted with no role of its own " \
          "— a self-registration, or a binding whose approving human resolves none — lands on the " \
          "EMPTY role set and gets a token with NO role claim, at an origin whose verbs branch on " \
          "one. Configure the default, naming the least-privileged role you declare: " \
          "Kiosk.configure { |c| c.registration_role = :#{declared.first} }. Or assign roles to " \
          "nobody — `c.roles = []` — which is the other supported shape: then no binding carries a " \
          "role and no token has one. Both are total; the mixture is what is refused " \
          "(kiosk.tech protocol.md Section 6.3)."
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.default_role_configuration_error(config: Kiosk.configuration)
        raise Kiosk::Server::Errors::ConfigurationError, message if message
      end

      # ── A TAIL THAT DIES WITH THE PROCESS IS NOT A TAIL ───────────────────
      #
      # A production origin that declares an event topic must keep its events
      # 24 hours, which the in-process {EventStore} cannot: it is empty after a
      # restart and unshared between workers. Raised, because a lost tail is
      # invisible afterwards. An origin with no topic never emits, so its store
      # is not checked. A class method so the condition is unit-testable.
      #
      # @param config [Kiosk::Configuration] normally `Kiosk.configuration`
      # @param production [Boolean] normally `Rails.env.production?`
      # @param topics [Array<String>] normally `Kiosk::Server::Events.known`
      # @return [String, nil]
      def self.ephemeral_event_store_error(config:, production:, topics:)
        return nil unless production

        declared = Array(topics).map { |topic| topic.to_s.strip }.reject(&:empty?)
        return nil if declared.empty?
        return nil unless config.event_store.is_a?(Kiosk::Server::EventStore)

        "[kiosk-server] this origin declares event topic(s) (#{declared.sort.join(', ')}) and its " \
          "`event_store` is the IN-PROCESS default. The operator keeps every event for 24 hours, " \
          "so a subscriber that reconnects with `since` misses nothing; this store is a Hash in " \
          "one process, not shared between Puma workers, dynos or pods, and a restart or deploy " \
          "loses every event inside that window, so the subscriber is told `truncated: true`. " \
          "Nothing reports it: a lost tail produces no error, no metric and no log line. Set the " \
          "durable store: c.event_store = Kiosk::Server::EventStores::ActiveRecord.new — which " \
          "`rails generate kiosk:install` writes into the initializer, beside the " \
          "`#{Kiosk.configuration.schema}.events` migration it writes for it."
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.ephemeral_event_store_error(
          config: Kiosk.configuration,
          production: ::Rails.env.production?,
          topics: Kiosk::Server::Events.known,
        )
        raise Kiosk::Server::Errors::ConfigurationError, message if message
      end

      # ── AN ADOPTER CROSSING A MAJOR STOPS AT IT ───────────────────────────
      #
      # `<schema>.schema_major()` records which MAJOR of the Kiosk schema this
      # database carries ({SchemaDefinitions.schema_major_sql}). A gem two or
      # more majors ahead of it cannot take that database forward, because the
      # migrations for the majors in between are not in this gem: each major
      # drops the previous one's chain and publishes a squashed genesis in its
      # place. So the jump is refused here, naming both numbers, rather than
      # discovered as a missing column on the first query.
      #
      # ONE MAJOR AHEAD IS THE UPGRADE ITSELF and boots: `db:migrate` runs
      # inside a booted application, so refusing it would make the upgrade
      # unreachable. A gem BEHIND the recorded major boots too — refusing a
      # deploy rollback would turn it into an outage.
      #
      # A database with no marker — one provisioned before the marker shipped —
      # is not accused: {.recorded_schema_major} answers nil and this passes.
      #
      # The condition is a CLASS METHOD for the reason its three siblings above
      # give: an `after_initialize` body is reachable only by booting a real
      # application, and a control whose condition cannot be unit-tested is a
      # control nobody can prove fires.
      #
      # @param schema_major [Integer, nil] normally {.recorded_schema_major}
      # @param gem_major [Integer] normally `Kiosk::Server::SCHEMA_MAJOR`
      # @return [String, nil]
      def self.schema_major_error(schema_major:, gem_major:)
        return nil if schema_major.nil?
        return nil if gem_major - schema_major < 2

        "[kiosk-server] this database's Kiosk schema is at major #{schema_major} and kiosk-server " \
          "#{Kiosk::Server::VERSION} installs major #{gem_major}. An adopter crossing a major stops " \
          "at it, so the migrations that take a major-#{schema_major} schema forward are not in this " \
          "gem at all: pin kiosk-server to major #{schema_major + 1}, run `bin/rails db:migrate`, and " \
          "repeat one major at a time. See the kiosk-server README, \"Upgrading\"."
      end

      # The major recorded in this database, or nil when there is nothing to
      # read: no database, no connection, no kiosk schema, or a schema laid down
      # before the marker existed. Absence is not an answer about the major, so
      # it is not one the check can act on — and a boot that runs before
      # `db:create` must not raise.
      #
      # @param schema [String, nil] normally `Kiosk.configuration.schema`
      # @return [Integer, nil]
      def self.recorded_schema_major(schema: nil)
        schema ||= Kiosk.configuration.schema
        ::ActiveRecord::Base.lease_connection
          .select_value(%(SELECT "#{schema}".schema_major()))&.to_i
      rescue ::ActiveRecord::ActiveRecordError
        nil
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.schema_major_error(
          schema_major: Kiosk::Server::Engine.recorded_schema_major,
          gem_major: Kiosk::Server::SCHEMA_MAJOR,
        )
        raise Kiosk::Server::Errors::ConfigurationError, message if message
      end

      # Root-relative discovery surface. `routes.append` blocks run when the
      # host's route set is FINALIZED — after config/routes.rb has been
      # drawn — so the mount is already visible when the gate below asks
      # whether this engine is mounted at all. Re-evaluated on every dev-mode
      # routes reload.
      initializer "kiosk-server.root_discovery_routes" do |app|
        app.routes.append do
          next unless Kiosk::Server::Engine.mounted_in?(app.routes)

          # agents.txt / agents.json are ROOT-served per the agents.txt v1.0
          # standard; the .well-known trio per RFC 8615; auth.md is the
          # root-level human/agent auth handbook agents.txt points at.
          get "/agents.txt",  to: "kiosk/server/discovery#agents_txt"
          get "/agents.json", to: "kiosk/server/discovery#agents_json"
          get "/auth.md",     to: "kiosk/server/discovery#auth_md"
          get "/.well-known/agent-configuration", to: "kiosk/server/discovery#agent_configuration"
          get "/.well-known/kiosk.json",          to: "kiosk/server/discovery#kiosk_json"
          get "/.well-known/api-catalog",         to: "kiosk/server/discovery#api_catalog"
        end
      end

      # Everything mount-prefixed. `isolate_namespace` scopes the drawer to
      # the kiosk/server controller namespace, so "wire#schema" resolves to
      # Kiosk::Server::WireController#schema.
      routes do
        # The RESERVED wire endpoints. They are drawn here for one reason:
        # they are the wire's OWN, not the operator's — their paths and their
        # answers are the spec's — and this table is where the protocol plane
        # lives. The operator's verbs are not here at all (see the end of this
        # table); the mount is drawn FIRST in their routes file, so every line
        # here wins over anything they write by Rails' own first-match.
        #
        # `pay` is drawn unconditionally: a host with no payment_provider
        # answers it with `module_not_served` (501, "this operator does not
        # serve the payment module"), and discovery already drops `pay` from
        # the advertised capabilities. 501 and NOT 403: whether this origin
        # does payments at all is a fact about the ORIGIN and true of every
        # caller, while `forbidden` means "authenticated, but this identity
        # may not do this".
        #
        # `schema` resolves no identity — it is PUBLIC, like `openapi.json`
        # below: it answers {SchemaDocument}, derived at boot, under a public
        # cache policy. It is still drawn HERE rather than beside the discovery
        # routes because it is mount-relative — it describes THIS wire, and its
        # URL derives from the discovery document's `endpoint`.
        get  "schema", to: "wire#schema"
        post "pay",    to: "wire#pay"

        # `payment_setup` and the page a payment provider returns the human's
        # browser to. Drawn unconditionally like `pay`, and answered
        # `module_not_served` without a payment_provider.
        post "payment_setup",        to: "verb#create", defaults: { kiosk_verb: "payment_setup" }
        get  "payment_setup/return", to: "payment_setup#show"

        # THE EVENT STREAM — drawn here for the reason `schema` and `pay` are:
        # its path and its answers are the spec's, not the operator's.
        #
        # The mounted app is OURS ({EventsCable}) rather than
        # `ActionCable.server`, so a host already running channels of its own
        # keeps its connection class and its forgery protection untouched — we
        # never write to the app-global Action Cable config at all.
        #
        # `internal: true, anchor: true` are Action Cable's own mount flags
        # (its engine.rb uses the same pair) and neither is decorative: the
        # route is not part of the operator's named surface, and the upgrade
        # must match at exactly this path rather than as a prefix.
        #
        # `events` is in {HandlerMixin::RESERVED_NAMES} too: that list and THIS
        # table move together.
        #
        # Drawn unconditionally, like `pay` and `agents/kyc`: an origin that
        # declares no topic answers it `module_not_served` (501, "this operator
        # does not serve the events module"), and discovery already drops
        # `events` from the advertised capabilities and publishes no
        # `events_url`. {EventsCable.serve} is where that answer lives.
        mount Kiosk::Server::EventsCable::RACK_APP => "events",
              internal: true, anchor: true, as: :kiosk_events

        # kiosk-pop auth plane (challenge-response proof-of-possession).
        get  "auth/challenge", to: "auth#challenge"
        post "auth/register",  to: "auth#register"
        post "auth/login",     to: "auth#login"
        post "auth/revoke",    to: "auth#revoke"

        # JWKS — under the MOUNT (RFC 8615 applies to the origin root; the
        # wire pins this one under <endpoint> and auth.md advertises it
        # there).
        get ".well-known/jwks.json", to: "jwks#show"

        # The DERIVED OpenAPI description. Drawn here, in the mounted table,
        # so the literal `.json` path wins by first-match over the appended
        # refusal pair, which would otherwise read it as the verb `openapi` in
        # the `json` format. It needs no entry in
        # {HandlerMixin::RESERVED_NAMES}: `openapi.json` is not a legal verb
        # name (§8.1 forbids the dot), so no declaration can collide with it,
        # and an operator verb literally called `openapi` stays reachable at
        # `<endpoint>/openapi`. PUBLIC, on the same terms as
        # `schema` above. PROVISIONAL — this line and
        # `open_api{,_controller}.rb` are the whole of it.
        get "openapi.json", to: "open_api#show"

        # KYC attestation. Unconditional for the same reason as `pay`: with
        # no kyc_public_key configured the verifier rejects with a
        # `module_not_served` (501) problem document, on the same
        # fact-about-the-origin reading, and hosts that never advertise KYC
        # lose nothing.
        post "agents/kyc", to: "kyc_attestation#create"

        # `request_kyc` and the KYC provider's callback. Drawn unconditionally
        # like `agents/kyc`, and answered `module_not_served` without a
        # kyc_provider.
        post "request_kyc",  to: "verb#create", defaults: { kiosk_verb: "request_kyc" }
        post "kyc/callback", to: "kyc_callback#create"

        # Claim flow (agent-initiated; auth.md "User Claimed") — the
        # RFC 8628 wire.
        post "oauth/device_authorization", to: "oauth_device_authorization#create"
        post "oauth/token",                to: "oauth_token#create"
        get  "oauth/device/verify",        to: "device_verify#show"
        post "oauth/device/verify",        to: "device_verify#create"

        # Link flow (human-initiated; Kiosk extension) + unlink.
        post "auth/link",   to: "auth#link"
        post "auth/claim",  to: "auth#claim"
        post "auth/unlink", to: "auth#unlink"

        # «Link an assistant» page (HTML shim over the same services). The
        # page's own forms post to link/update/unlink, so all four routes
        # ship together.
        get  "auth/assistants",        to: "assistants#show"
        post "auth/assistants/link",   to: "assistants#link"
        post "auth/assistants/update", to: "assistants#update"
        post "auth/assistants/unlink", to: "assistants#unlink"

        # The operator's verbs are routed by the operator, one line each, in
        # config/routes/kiosk.rb.
      end
    end
  end
end
