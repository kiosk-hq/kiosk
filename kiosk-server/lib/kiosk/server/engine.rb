# frozen_string_literal: true

# The Rails engine. `kiosk` in config/routes.rb mounts it at the configured mount_path,
# drawing the protocol plane under the mount and the discovery documents at the root.
# `rails` first: rails/engine needs its core_ext.
require 'rails'
require 'rails/engine'

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
      initializer 'kiosk-server.middleware' do |app|
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::HeadersMiddleware
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::IssuerMiddleware
      end

      # Credential-bearing protocol fields, kept out of the `Parameters:` log line.
      # Whole-key matches, so an operator's own `promo_code` is left alone.
      FILTERED_PARAMETERS = %w[
        client_assertion new_client_assertion code device_code kyc_jws
        checkout_mandate payment_mandate
      ].map { |field| /\A#{field}\z/ }.freeze

      initializer 'kiosk-server.filter_parameters' do |app|
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

        message = '[kiosk-server] no queries or actions are registered. Put handler controllers ' \
                  "(classes including Kiosk::Handler) in #{Kiosk::Server::HandlerRegistrations::HANDLERS_DIR}."
        ::Rails.logger ? ::Rails.logger.warn(message) : warn(message)
      end

      # A wrong `issuer` refuses every client assertion with "client assertion audience mismatch".
      # Warned, not raised: an operator seeds before the public origin exists.
      LOOPBACK_ISSUER =
        %r{\A(?:https?://)?(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\])(?::\d+)?/?\z}i

      # The boot-time configuration checks. Each answers a message, or nil when the configuration is sound.
      module BootChecks
        ISSUER_UNSET =
          '[kiosk-server] `c.issuer` is not set, so every client assertion is refused ' \
          'with "client assertion audience mismatch". Set it to the origin assistants dial: ' \
          'Kiosk.configure { |c| c.issuer = "https://api.example.com" }.'

        ISSUER_LOOPBACK =
          '[kiosk-server] The served origin %<origin>s is a loopback origin; no assistant can ' \
          'reach it outside development and test. Set `c.issuer` and `c.additional_origins` ' \
          'to public origins.'

        DEFAULT_ROLE =
          'An assistant admitted without a role would get a token with no role claim. ' \
          'Set the least-privileged declared role as the default ' \
          '(Kiosk.configure { |c| c.registration_role = :%<first>s }), or declare no roles (`c.roles = []`).'

        def issuer_warning(config:, local:)
          issuer = config.issuer.to_s.strip
          return ISSUER_UNSET if issuer.empty?
          return nil if local

          loopback = [issuer, *config.additional_origins].map { |o| o.to_s.strip }
                                                         .find { |o| LOOPBACK_ISSUER.match?(o) }
          format(ISSUER_LOOPBACK, origin: loopback.inspect) if loopback
        end

        # An origin that declares roles must configure a `registration_role` among
        # them; an origin with no roles needs none.
        def default_role_configuration_error(config:)
          declared = Array(config.roles).map(&:to_s).reject(&:empty?)
          return nil if declared.empty?

          configured = config.registration_role.to_s.strip
          return nil if declared.include?(configured)

          "#{default_role_head(config, declared, configured)} #{format(DEFAULT_ROLE, first: declared.first)}"
        end

        private

        def default_role_head(config, declared, configured)
          roles = declared.join(', ')
          return "[kiosk-server] this origin declares roles (#{roles}) and configures no `registration_role`." if configured.empty?

          "[kiosk-server] this origin declares roles (#{roles}) and its " \
            "`registration_role` is #{config.registration_role.inspect}, which is not one of them."
        end
      end
      extend BootChecks

      config.after_initialize do
        message = Kiosk::Server::Engine.issuer_warning(
          config: Kiosk.configuration, local: ::Rails.env.local?
        )
        next unless message

        ::Rails.logger ? ::Rails.logger.warn(message) : warn(message)
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.default_role_configuration_error(config: Kiosk.configuration)
        raise Kiosk::Server::Errors::ConfigurationError, message if message
      end

      # A production origin that serves events needs a shared cable adapter; this raises without one.
      config.after_initialize do
        Kiosk::Server::EventsCable.cable_config if ::Rails.env.production? && Kiosk::Server::Events.known.any?
      end

      # `routes.append` runs after config/routes.rb is drawn, so the mount is visible here.
      initializer 'kiosk-server.root_discovery_routes' do |app|
        app.routes.append do
          next unless Kiosk::Server::Engine.mounted_in?(app.routes)

          get '/agents.txt',  to: 'kiosk/server/discovery#agents_txt'
          get '/agents.json', to: 'kiosk/server/discovery#agents_json'
          get '/auth.md',     to: 'kiosk/server/discovery#auth_md'
          get '/.well-known/kiosk.json',          to: 'kiosk/server/discovery#kiosk_json'
          get '/.well-known/api-catalog',         to: 'kiosk/server/discovery#api_catalog'
          get '/.well-known/oauth-authorization-server', to: 'kiosk/server/discovery#oauth_authorization_server'
          get '/.well-known/agent-skills/index.json',    to: 'kiosk/server/discovery#agent_skills_index'
          get '/.well-known/ard.json',                   to: 'kiosk/server/discovery#ard'
          get '/.well-known/ai-catalog.json',            to: 'kiosk/server/discovery#ard'
          get '/.well-known/oauth-protected-resource',   to: 'kiosk/server/discovery#oauth_protected_resource'
        end
      end

      routes do
        # The protocol's reserved endpoints. The mount is drawn first in the host's
        # routes, so these win by first-match. Optional modules are drawn
        # unconditionally and answer `module_not_served` (501) when not configured.
        # `schema` resolves no identity — it is PUBLIC, like `openapi.json`
        get  'schema', to: 'wire#schema'
        post 'pay',    to: 'wire#pay'

        post 'payment_setup',        to: 'verb#create', defaults: { kiosk_verb: 'payment_setup' }
        get  'payment_setup/return', to: 'payment_setup#show'

        # Our own cable app, so a host's Action Cable config is never touched.
        # `events` is also in {HandlerMixin::RESERVED_NAMES}; keep the two in step.
        mount Kiosk::Server::EventsCable::RACK_APP => 'events', internal: true, anchor: true, as: :kiosk_events

        # RFC 7591 registration and the token endpoint (RFC 6749) are core.
        post 'oauth/register', to: 'oauth_registration#create'
        post 'oauth/token',    to: 'oauth_token#create'
        post 'auth/rotate',    to: 'auth#rotate'

        # JWKS sits under the mount, not the origin root.
        get '.well-known/jwks.json', to: 'jwks#show'

        # Drawn here so the literal `.json` path wins over the verb routes.
        get 'openapi.json', to: 'open_api#show'

        post 'agents/kyc', to: 'kyc_attestation#create'

        post 'request_kyc',  to: 'verb#create', defaults: { kiosk_verb: 'request_kyc' }
        post 'kyc/callback', to: 'kyc_callback#create'

        # RFC 8628 device flow.
        post 'oauth/device_authorization', to: 'oauth_device_authorization#create'
        get  'oauth/device/verify',        to: 'device_verify#show'
        post 'oauth/device/verify',        to: 'device_verify#create'

        post 'auth/link',   to: 'auth#link'
        post 'auth/claim',  to: 'auth#claim'
        post 'auth/unlink', to: 'auth#unlink'

        get  'auth/assistants',        to: 'assistants#show'
        post 'auth/assistants/link',   to: 'assistants#link'
        post 'auth/assistants/update', to: 'assistants#update'
        post 'auth/assistants/unlink', to: 'assistants#unlink'

        # The operator routes its own verbs with `kiosk do … end` in config/routes.rb.
      end
    end
  end
end
