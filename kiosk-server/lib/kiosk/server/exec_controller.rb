# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests) by simply not loading this file when ActionController::API
# isn't around. Engine wires up the route when Rails is present.

if defined?(::ActionController::API)
  require "json"
  require "kiosk/server/executor"
  require "kiosk/server/errors"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # POST /kiosk/exec — Rails controller wrapping {Executor}.
      # See design spec §5.4 «Server side» for the contract.
      #
      # Wire request body (JSON):
      #
      #   { "command": "sql", "body": { "sql": "SELECT 1" } }
      #   { "command": "run", "body": { "name": "ping", "...": "..." } }
      #
      # Wire response (JSON): success per {Result#to_envelope}, error per
      # {Errors::Base#to_envelope}.
      #
      # Identity resolution: tries `Kiosk.configuration.agent_idp` first
      # (the typical agent-channel case), falls back to
      # `Kiosk.configuration.user_idp` (web/mobile channels mounted
      # through the same endpoint). Adapter `#verify(request)` returns a
      # {Kiosk::Identity} or `nil`; `nil` becomes 401.
      class ExecController < ::ActionController::API
        def exec
          identity = resolve_identity!
          parsed   = parse_body!

          result = Executor.call(
            kind:       parsed[:command] || parsed[:kind],
            args:       parsed[:body]    || parsed[:args],
            identity:   identity,
            connection: connection_for(identity),
          )

          render_envelope(result.to_envelope, status: result.http_status)
        rescue Errors::Base => e
          render_envelope(e.to_envelope, status: e.http_status)
        end

        private

        def resolve_identity!
          idp = Kiosk.configuration.agent_idp || Kiosk.configuration.user_idp
          raise Errors::Unauthenticated, "no IdP configured" if idp.nil?

          identity = idp.verify(request)
          raise Errors::Unauthenticated, "no identity resolved from request" if identity.nil?

          identity
        end

        def parse_body!
          raw = request.body.read
          return {} if raw.nil? || raw.empty?

          parsed = JSON.parse(raw, symbolize_names: true)
          unless parsed.is_a?(Hash)
            raise Errors::BadRequest, "request body must be a JSON object"
          end

          parsed
        rescue JSON::ParserError => e
          raise Errors::BadRequest, "invalid JSON body: #{e.message}"
        end

        # Default: host's primary ActiveRecord connection. Satellite-mode
        # / app_role connection-pool plumbing per spec §7.7 lands in a
        # follow-up release.
        def connection_for(_identity)
          ::ActiveRecord::Base.connection
        end

        def render_envelope(envelope, status:)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: envelope, status: status
        end
      end
    end
  end
end
