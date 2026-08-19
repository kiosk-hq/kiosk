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
    # {Errors::Base#to_envelope} — the 0.3 envelope. These four endpoints keep
    # it until the cutover slice, which deletes `query`/`run` and moves
    # `schema`/`pay` onto the 0.4 shape together with the eight demos that
    # read it (T-074 = A). The 0.4 shape — payload verbatim, errors as RFC
    # 9457 problem documents — is served TODAY by {VerbController}, which
    # subclasses this one and overrides only the two render seams.
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

        execute_wire(command: command, args: body, identity: identity)
      end

      # The toll, the session and the render — everything after the arguments
      # are in hand and the identity is resolved.
      #
      # Shared with {VerbController}, the 0.4 per-verb wire, which reaches the
      # same three gates by a different route: its verb name is a PATH SEGMENT
      # and a query's arguments arrive in the query string, so it does its own
      # parsing and then hands the result here. Both wires therefore compute
      # the SAME PoW fingerprint for the same call, which is what lets a proof
      # issued on one be spent on the other while both are served.
      #
      # @param command [Symbol] the gate/policy verb — still one of
      #   {Executor::VERBS}, because `reputation_factors` and
      #   `Policy#challenge_for` both take it as `verb:` and every shipped
      #   policy branches on those four symbols.
      # @param name [String, nil] the query/action wire name when the caller
      #   knows it (the per-verb wire), nil when it is inside `args` (0.3).
      def execute_wire(command:, args:, identity:, name: nil)
        # The fingerprint binds the challenge to `command` + the canonical JSON
        # of the arguments. On the per-verb wire the name is not IN the
        # arguments, so it is folded back in HERE — for the digest only, never
        # for the handler — which reproduces the 0.3 fingerprint byte for byte.
        # (Widening the formula to `"<METHOD> <verb>\n<args>"`, which design
        # §3.4 recommends and which stops depending on there being a `name`
        # slot at all, rides the 0.4 cutover slice with the rest of the wire
        # break. No verb in the tree declares an argument called `name`, so
        # nothing is shadowed by the merge today.)
        toll!(
          identity: identity,
          command:  command,
          body:     name.nil? ? args : args.merge(name: name),
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
            args:       args,
            identity:   identity,
            connection: connection_for(identity),
            name:       name,
          )
        end

        render_result(result)
      end

      # THE TOLL, on its own — the whole of what a caller pays before a Kiosk
      # surface answers, and nothing else.
      #
      # It is its own method because {OpenApiController} has to pay it with no
      # {Executor} call behind it: the derived OpenAPI document renders the
      # SAME catalog `GET <endpoint>/schema` renders, so it is tolled as
      # `:schema`. Left untolled it would be a free path to information a
      # reputation policy is charging for — the shipped
      # {Kiosk::Reputation::Policies::RateAndReputation} ignores `verb:` and
      # prices every wire call, `schema` included.
      #
      # @param identity [Kiosk::Identity] the resolved caller
      # @param command [Symbol] the gate/policy verb — one of {Executor::VERBS},
      #   because `reputation_factors` and `Policy#challenge_for` both take it
      #   as `verb:` and every shipped policy branches on those four symbols
      # @param body [Hash] what the challenge fingerprint binds to
      def toll!(identity:, command:, body:)
        # Read the submitted proof(s) from the `Kiosk-PoW` request HEADER
        # (ADR-0022), NOT the body: the body is now ONLY verb args, so the
        # challenge fingerprint binds to the plain body untouched, and a GET
        # (schema) can carry its proof via the header too (a GET has no body).
        # proofs_from_header raises Errors::BadRequest (→ 400) on malformed
        # header JSON, inside the caller's rescue.
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

        PowGate.gate(identity: identity, command: command, body: body, pow: pow)
      end

      # How a SUCCESS reaches the wire. Its own method because the two wires
      # answer differently and this is the whole of the difference:
      # `POST <endpoint>/{query,run}`, `GET <endpoint>/schema` and
      # `POST <endpoint>/pay` answer the 0.3 envelope (here);
      # {VerbController} overrides it with the 0.4 shape — the handler's
      # rendered payload, verbatim (T-072 = C).
      def render_result(result)
        render_wire_body(result.to_envelope, status: result.http_status)
      end

      # How an ERROR reaches the wire. Same split: the 0.3 error envelope
      # here, an RFC 9457 problem document in {VerbController}.
      def render_wire_error(error)
        render_wire_body(error.to_envelope, status: error.http_status, error: error)
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
      #
      # `lease_connection`, not `connection` (K-654): Rails 8.1 soft-deprecates
      # `ActiveRecord::Base.connection`, and under
      # `config.active_record.permanent_connection_checkout = :disallowed` it
      # RAISES — so the whole wire surface would 500 on a host that has opted
      # into the new default. The lease is the semantics this seam needs and
      # `with_connection` is deliberately not used: {SessionContext} sets four
      # transaction-local GUCs, and `pay` spans THREE separate transactions
      # around an irreversible capture, so every one of them must land on the
      # same connection for the whole request — which is exactly what a lease
      # held "for the entire duration of the request" guarantees and what a
      # checked-back-in connection would not.
      def connection_for(_identity)
        ::ActiveRecord::Base.lease_connection
      end

      # The ONE place a wire response is written. Everything both wires must
      # carry regardless of body shape lives here: the three version-handshake
      # headers, the cache policy (design §3.3 — `Vary: Authorization,
      # Kiosk-PoW` on every wire response, `no-store` on a 402), the RFC 7235
      # challenge that de-overloads the two 402 gates, and any header the
      # error itself requires (`Allow` on a 405, RFC 9110 §15.5.6).
      #
      # @param body [Hash, Array] the response body, already in its final shape
      # @param status [Integer, Symbol] the HTTP status
      # @param error [Errors::Base, nil] the error being rendered, when it is one
      # @param content_type [String, nil] overrides `application/json` — the
      #   0.4 error path renders `application/problem+json`
      def render_wire_body(body, status:, error: nil, content_type: nil)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: ::Rack::Utils.status_code(status)
        )
        if error
          error.response_headers.each { |name, value| response.set_header(name, value) }
          if (challenge = www_authenticate_for(error))
            response.set_header("WWW-Authenticate", challenge)
          end
        end
        options = { json: body, status: status }
        options[:content_type] = content_type if content_type
        render(**options)
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
