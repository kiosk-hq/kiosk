# frozen_string_literal: true

# The wire surface. The engine draws the routes; hand-drawing them in the
# host's config/routes.rb remains the escape hatch.

require "action_controller"
require "json"
require "kiosk/server/current_request"
require "kiosk/server/executor"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "kiosk/server/pow_gate"
require "kiosk/server/request_validation"

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
      # Every Kiosk wire error — raised by the Executor, a gate, a verifier
      # or a handler dispatch — renders as the spec's error envelope from
      # this ONE seam (T-054), Rails' own idiom rather than a hand-rolled
      # rescue inside each action.
      rescue_from Errors::Base, with: :render_wire_error

      # REST verb: GET /kiosk/schema
      def schema
        run_command(:schema)
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

      def run_command(command)
        # parse_body! runs inside the action, so the rescue_from above covers
        # it: a malformed body raises Errors::BadRequest, which must render a
        # 400 envelope, not escape as an uncaught 500 (the same
        # parse-outside-rescue class fixed for
        # AuthController/KycAttestationController).
        body     = parse_body!
        identity = resolve_identity!

        # Read the submitted proof(s) from the `Kiosk-PoW` request HEADER
        # (ADR-0022), NOT the body: the body is now ONLY verb args, so the
        # challenge fingerprint binds to the plain body untouched, and a GET
        # (schema) can carry its proof via the header too (a GET has no body).
        # proofs_from_header raises Errors::BadRequest (→ 400) on malformed
        # header JSON, inside this rescue.
        pow = PowGate.proofs_from_header(request.get_header("HTTP_KIOSK_POW"))

        # Opt-in request-shape validation (UNIFORM-VALIDATION slice-1, K-479).
        # Only when the flag is on AND a proof was actually submitted: validate
        # each parsed proof against the vendored normative schema so a MALFORMED
        # proof (e.g. `{solutions:[…]}` instead of `{challenge:,nonce:}`) raises
        # a clear 400 with a shape hint — instead of PowGate silently ignoring
        # it and re-issuing a fresh 402 on every retry. An ABSENT proof is left
        # untouched (the initial request must still get its normal 402
        # challenge), and a WELL-FORMED proof passes through unchanged to the
        # gate below, which still does the real cryptographic check.
        if Kiosk.configuration.validate_requests && !PowGate.blank?(pow)
          RequestValidation.validate_proofs!(pow)
        end

        PowGate.gate(
          identity: identity,
          command:  command,
          body:     body,
          pow:      pow,
        )

        # Carry the resolved identity and the wire request down to the handler
        # layer. A handler registered as a controller action (`include
        # Kiosk::Action`) is dispatched as a Rails sub-request built from these:
        # the identity lands in `env["kiosk.identity"]` (readable as
        # `kiosk_identity`), and the caller's headers/address are seeded from
        # this env. Block handlers registered the old way ignore both.
        result = CurrentRequest.with(identity: identity, env: request.env) do
          Executor.call(
            kind:       command,
            args:       body,
            identity:   identity,
            connection: connection_for(identity),
          )
        end

        render_envelope(result.to_envelope, status: result.http_status)
      end

      def render_wire_error(error)
        render_envelope(error.to_envelope, status: error.http_status, error: error)
      end

      def resolve_identity!
        identity = IdentityResolution.resolve(request)
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
      # (the PoW N-challenge list / the payment_setup pointer). Keyed on the
      # wire CODE, not the exception class (T-054) — so a handler that
      # RENDERS `payment_setup_required` gets the same challenge header as
      # the gate that raises it. nil for every other code (no header
      # emitted; `payment_failed` deliberately bare — no scheme names it).
      #
      # The `Payment` scheme params (`realm`, `method`) are isolated here so a
      # change in the still-draft IETF scheme (draft-ryan-httpauth-payment) is
      # a one-place edit.
      def www_authenticate_for(error)
        issuer = Kiosk.configuration.issuer
        case error.code
        when "pow_required"
          %(Kiosk-PoW realm="#{issuer}")
        when "payment_setup_required"
          %(Payment realm="#{issuer}", method="ap2")
        end
      end
    end
  end
end
