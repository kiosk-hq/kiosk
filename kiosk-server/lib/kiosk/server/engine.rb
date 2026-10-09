# frozen_string_literal: true

# The Rails engine. `mount Kiosk::Server::Engine => Kiosk.configuration.mount_path`
# draws the protocol plane under the mount and the discovery documents at the root.
# `rails` first: rails/engine needs its core_ext.
require "rails"
require "rails/engine"
require "solid_cable"

module Kiosk
  module Server
    class Engine < ::Rails::Engine
      isolate_namespace Kiosk::Server

      # True when this engine is mounted anywhere in +route_set+.
      def self.mounted_in?(route_set)
        route_set.routes.any? do |route|
          app = route.app
          app.respond_to?(:app) && (app.app == self || app.app.is_a?(self))
        end
      end

      # Outside ShowExceptions, so routing 404s and unhandled 500s carry the
      # version headers too (§3.6); below HostAuthorization/SSL, which answer
      # before the application is reached.
      initializer "kiosk-server.middleware" do |app|
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::HeadersMiddleware
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::IssuerMiddleware
      end

      # Credential-bearing wire fields, kept out of the `Parameters:` log line.
      # Whole-key matches, so an operator's own `promo_code` is left alone.
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

      # A wrong `issuer` refuses every proof with "proof audience mismatch".
      # Warned, not raised: an operator seeds before the public origin exists.
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

      # An origin that declares roles must configure a `registration_role` among
      # them (protocol.md §6.3); an origin with no roles needs none.
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

      # A production origin with event topics must keep 24 hours of events,
      # which the in-process {EventStore} cannot.
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

      # `routes.append` runs after config/routes.rb is drawn, so the mount is visible here.
      initializer "kiosk-server.root_discovery_routes" do |app|
        app.routes.append do
          next unless Kiosk::Server::Engine.mounted_in?(app.routes)

          get "/agents.txt",  to: "kiosk/server/discovery#agents_txt"
          get "/agents.json", to: "kiosk/server/discovery#agents_json"
          get "/auth.md",     to: "kiosk/server/discovery#auth_md"
          get "/.well-known/agent-configuration", to: "kiosk/server/discovery#agent_configuration"
          get "/.well-known/kiosk.json",          to: "kiosk/server/discovery#kiosk_json"
          get "/.well-known/api-catalog",         to: "kiosk/server/discovery#api_catalog"
        end
      end

      routes do
        # The wire's reserved endpoints. The mount is drawn first in the host's
        # routes, so these win by first-match. Optional modules are drawn
        # unconditionally and answer `module_not_served` (501) when not configured.
        # `schema` resolves no identity — it is PUBLIC, like `openapi.json`
        get  "schema", to: "wire#schema"
        post "pay",    to: "wire#pay"

        post "payment_setup",        to: "verb#create", defaults: { kiosk_verb: "payment_setup" }
        get  "payment_setup/return", to: "payment_setup#show"

        # Our own cable app, so a host's Action Cable config is never touched.
        # `events` is also in {HandlerMixin::RESERVED_NAMES}; keep the two in step.
        mount Kiosk::Server::EventsCable::RACK_APP => "events",
              internal: true, anchor: true, as: :kiosk_events

        get  "auth/challenge", to: "auth#challenge"
        post "auth/register",  to: "auth#register"
        post "auth/login",     to: "auth#login"
        post "auth/revoke",    to: "auth#revoke"

        # JWKS sits under the mount, not the origin root.
        get ".well-known/jwks.json", to: "jwks#show"

        # Drawn here so the literal `.json` path wins over the verb routes.
        get "openapi.json", to: "open_api#show"

        post "agents/kyc", to: "kyc_attestation#create"

        post "request_kyc",  to: "verb#create", defaults: { kiosk_verb: "request_kyc" }
        post "kyc/callback", to: "kyc_callback#create"

        # RFC 8628 device flow.
        post "oauth/device_authorization", to: "oauth_device_authorization#create"
        post "oauth/token",                to: "oauth_token#create"
        get  "oauth/device/verify",        to: "device_verify#show"
        post "oauth/device/verify",        to: "device_verify#create"

        post "auth/link",   to: "auth#link"
        post "auth/claim",  to: "auth#claim"
        post "auth/unlink", to: "auth#unlink"

        get  "auth/assistants",        to: "assistants#show"
        post "auth/assistants/link",   to: "assistants#link"
        post "auth/assistants/update", to: "assistants#update"
        post "auth/assistants/unlink", to: "assistants#unlink"

        # The operator routes its own verbs in config/routes/kiosk.rb.
      end
    end
  end
end
