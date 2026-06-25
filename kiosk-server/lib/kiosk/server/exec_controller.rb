# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests) by simply not loading this file when ActionController::API
# isn't around. Engine wires up the route when Rails is present.

if defined?(::ActionController::API)
  require "json"
  require "kiosk/server/executor"
  require "kiosk/server/errors"
  require "kiosk/server/headers"
  require "kiosk/server/pow_gate"

  module Kiosk
    module Server
      # POST /kiosk/exec — Rails controller wrapping {Executor}.
      # See design spec §5.4 «Server side» for the contract.
      #
      # Wire request body (JSON):
      #
      #   { "command": "query", "body": { "name": "menu_by_restaurant", "restaurant": "..." } }
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

          command = parsed[:command] || parsed[:kind]
          args    = parsed[:body]    || parsed[:args]

          # PoW gate: no-op when reputation_policy is nil (the default).
          # Raises Errors::PowRequired (402) or Errors::Forbidden (403) on
          # challenge / bad-proof; returns :proceed otherwise.
          PowGate.gate(
            identity: identity,
            command:  command,
            body:     args,
            pow:      parsed[:pow],
          )

          result = Executor.call(
            kind:       command,
            args:       args,
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
          # `request.raw_post` is Rails-safe — works even if a prior
          # middleware (Rails' ParamsWrapper, for example) has already
          # consumed the body stream. We deliberately bypass `params`
          # because Executor wants the unwrapped wire shape, not the
          # controller-name-wrapped form ActionController::API materialises.
          raw = request.raw_post
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
