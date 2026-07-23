# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::API)` guard below means it only defines
# WireController when ActionController::API is present. In plain Ruby the
# require is a no-op. Hosts mount the route in their own config/routes.rb.

if defined?(::ActionController::API)
  require "json"
  require "kiosk/server/executor"
  require "kiosk/server/errors"
  require "kiosk/server/headers"
  require "kiosk/server/pow_gate"

  module Kiosk
    module Server
      # REST wire surface — Rails controller wrapping {Executor}.
      # See the Endpoints section of the spec for the contract.
      #
      # REST endpoints (one per verb):
      #   GET  /kiosk/schema
      #   POST /kiosk/query  { "name": "catalog", ... }
      #   POST /kiosk/run    { "name": "create_order", ... }
      #   POST /kiosk/pay    { "intent_mandate_jws": "...", ... }
      #
      # Wire response (JSON): success per {Result#to_envelope}, error per
      # {Errors::Base#to_envelope}.
      #
      # Identity resolution: {IdentityResolution.resolve} — the
      # agent IdP first (`Kiosk.configuration.agent_idp`, defaulting to the
      # bundled kiosk-pop DefaultAgentIdp so a zero-config install works),
      # then `Kiosk.configuration.user_idp` (web/mobile sessions on the same
      # endpoints). Adapter `#verify(request)` returns a {Kiosk::Identity}
      # or `nil`; nothing resolved becomes 401.
      class WireController < ::ActionController::API
        # REST verb: GET /kiosk/schema
        #
        # Anonymous-readable: the schema is the machine-readable API description,
        # so it does NOT require a resolved identity (unlike query/run/pay). The
        # PoW gate still applies, so an operator MAY toll it anti-scrape.
        def schema
          run_command(:schema, anonymous_ok: true)
        end

        # REST verb: POST /kiosk/query
        def query
          run_command(:query)
        end

        # REST verb: POST /kiosk/run
        def run
          run_command(:run)
        end

        # REST verb: POST /kiosk/pay
        def pay
          run_command(:pay)
        end

        private

        def run_command(command, anonymous_ok: false)
          # parse_body! runs INSIDE the rescue below: a malformed body raises
          # Errors::BadRequest, which must render a 400 envelope, not escape as
          # an uncaught 500 (the same parse-outside-rescue class fixed
          # for AuthController/KycAttestationController).
          args     = parse_body!
          identity = resolve_identity!(anonymous_ok: anonymous_ok)

          # Pull the submitted proof out of the body: it is a sibling of the verb
          # args, and must be excluded from BOTH the challenge fingerprint (which
          # binds to the pow-less original request) and the Executor dispatch.
          pow, body = PowGate.split_pow(args)

          PowGate.gate(
            identity: identity,
            command:  command,
            body:     body,
            pow:      pow,
          )

          result = Executor.call(
            kind:       command,
            args:       body,
            identity:   identity,
            connection: connection_for(identity),
          )

          render_envelope(result.to_envelope, status: result.http_status)
        rescue Errors::Base => e
          render_envelope(e.to_envelope, status: e.http_status, error: e)
        end

        # Resolve the request principal. With `anonymous_ok: true` (public verbs
        # like schema) a request that resolves to nothing returns nil instead of
        # raising 401 — the verb is served anonymously (still PoW-gateable).
        def resolve_identity!(anonymous_ok: false)
          identity = IdentityResolution.resolve(request)
          if identity.nil? && !anonymous_ok
            raise Errors::Unauthenticated, "no identity resolved from request"
          end

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
        # / app_role connection-pool plumbing lands in a
        # follow-up release.
        def connection_for(_identity)
          ::ActiveRecord::Base.connection
        end

        def render_envelope(envelope, status:, error: nil)
          Kiosk::Server::Headers.add_to(response.headers)
          if error && (challenge = www_authenticate_for(error))
            response.set_header("WWW-Authenticate", challenge)
          end
          render json: envelope, status: status
        end

        # RFC 7235 challenge header that de-overloads the two 402 gates:
        # the header NAMES the gate, the JSON body still CARRIES the payload
        # (the PoW N-challenge list / the payment_setup pointer). Keyed purely on
        # the error class; nil for every non-402 error (no header emitted).
        #
        # The `Payment` scheme params (`realm`, `method`) are isolated here so a
        # change in the still-draft IETF scheme (draft-ryan-httpauth-payment) is
        # a one-place edit.
        def www_authenticate_for(error)
          issuer = Kiosk.configuration.issuer
          case error
          when Errors::PowRequired
            %(Kiosk-PoW realm="#{issuer}")
          when Errors::PaymentSetupRequired
            %(Payment realm="#{issuer}", method="ap2")
          end
        end
      end
    end
  end
end
