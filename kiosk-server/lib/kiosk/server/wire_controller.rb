# frozen_string_literal: true

# The wire surface. The engine draws the routes; hand-drawing them in the
# host's config/routes.rb remains the escape hatch.

require "action_controller"
require "action_dispatch/http/parameters"
require "json"
require "kiosk/server/current_request"
require "kiosk/server/executor"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "kiosk/server/pow_gate"
require "kiosk/server/request_validation"

module Kiosk
  module Server
    # The wire's own two RESERVED endpoints, and the base class every other
    # wire surface inherits its seams from:
    #
    #   GET  <endpoint>/schema   the catalog
    #   POST <endpoint>/pay      settle an AP2 cart
    #
    # Every OTHER verb is one endpoint per verb, served by {VerbController},
    # which subclasses this one. `POST <endpoint>/query` and
    # `POST <endpoint>/run` — 0.3's multiplexed pair — were DELETED at the 0.4
    # cutover (T-074 = A). There is no route left, no tombstone and no hint
    # payload: one wire, one conformance surface.
    #
    # Wire response (JSON): success is the handler's payload VERBATIM
    # ({Result#to_payload}), error is an RFC 9457 problem document
    # ({Errors::Base#to_problem}) under `application/problem+json`. Both seams
    # live HERE, not in the subclass, because after the cutover there is only
    # one answer shape — the two-shapes split that put them in
    # {VerbController} was the build-time intermediate, and it is over.
    #
    # Identity resolution: {IdentityResolution.resolve} — the
    # agent IdP first (`Kiosk.configuration.agent_idp`, defaulting to the
    # bundled kiosk-pop DefaultAgentIdp so a zero-config install works),
    # then `Kiosk.configuration.user_idp` (web/mobile sessions on the same
    # endpoints). Adapter `#verify(request)` returns a {Kiosk::Identity}
    # or `nil`; nothing resolved becomes 401.
    class WireController < ::ActionController::API
      # Every Kiosk wire error — raised by the Executor, a gate, a verifier
      # or a handler dispatch — renders as the spec's problem document from
      # this ONE seam (T-054), Rails' own idiom rather than a hand-rolled
      # rescue inside each action.
      rescue_from Errors::Base, with: :render_wire_error

      # A body that is not JSON at all, answered as a Kiosk `bad_request`
      # rather than as Rails' generic 400.
      #
      # WHY IT NEEDS ITS OWN LINE. {#parse_body!} already turns a
      # `JSON::ParserError` into {Errors::BadRequest} — but on the per-verb
      # wire it never gets the chance: {VerbController#serve} reads
      # `params[:kiosk_verb]` first, and touching `params` makes Rails parse
      # the body, so a malformed body raises out of the PARAMETER layer before
      # any Kiosk code runs. A Rails host's `rescue_responses` maps that to
      # 400, but renders it through PublicExceptions — an HTML or plain-text
      # body with no `code`. Every other refusal on this wire is a problem
      # document; without this line, malformed JSON would be the one hole in
      # the error contract, and the shape of the hole depends on the host's
      # exception app rather than on the protocol.
      rescue_from ::ActionDispatch::Http::Parameters::ParseError do |error|
        render_wire_error(
          Errors::BadRequest.new(
            "invalid JSON body: #{error.message}",
            hint: "an action's arguments are a JSON object in the request body; " \
                  "a query's are in the query string.",
          ),
        )
      end

      # GET <endpoint>/schema
      def schema
        run_command(:schema)
      end

      # POST <endpoint>/pay
      def pay
        run_command(:pay)
      end

      private

      # The two reserved endpoints. Their wire NAME is their command name —
      # `schema` and `pay` are both the gate/policy verb and the path segment
      # — so the name travels to the fingerprint exactly as a per-verb call's
      # does, and §3.4's `"<METHOD> <verb>"` formula needs no special case.
      def run_command(command)
        # parse_body! runs inside the action, so the rescue_from above covers
        # it: a malformed body raises Errors::BadRequest, which must render a
        # 400 problem document, not escape as an uncaught 500 (the same
        # parse-outside-rescue class fixed for
        # AuthController/KycAttestationController). `schema` is a GET and has
        # no body; raw_post is empty and this yields {}.
        body     = parse_body!
        identity = resolve_identity!

        execute_wire(command: command, args: body, identity: identity, name: command.to_s)
      end

      # The toll, the session and the render — everything after the arguments
      # are in hand and the identity is resolved.
      #
      # Shared with {VerbController}, which reaches the same three gates by a
      # different route: its verb name is a PATH SEGMENT and a query's
      # arguments arrive in the query string, so it does its own parsing and
      # then hands the result here.
      #
      # @param command [Symbol] the gate/policy verb — one of {Executor::VERBS},
      #   because `reputation_factors` and `Policy#challenge_for` both take it
      #   as `verb:` and every shipped policy branches on those four symbols.
      # @param name [String] the WIRE name — the path segment. `schema` and
      #   `pay` pass their own; a per-verb call passes the registered verb.
      def execute_wire(command:, args:, identity:, name:)
        # §3.4's fingerprint: SHA256("<METHOD> <verb>\n<canonical args>").
        #
        # It binds a challenge to the exact call — the HTTP method, the verb
        # name as it appears in the path, and the canonical JSON of the
        # arguments — so a proof solved for `GET /catalog?city=Lisbon` is
        # spendable on nothing else. 0.3's formula could not say this: with
        # every read multiplexed through one POST, the method was a constant
        # and the verb name had to be smuggled back INTO the arguments to
        # reach the digest at all. Widening it is the cutover's, because
        # reproducing the old digest byte for byte was what let one proof be
        # spent on either wire while both were served, and only one is now.
        toll!(identity: identity, command: command, name: name, body: args)

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
      # @param name [String] the WIRE verb name, as it appears in the path —
      #   half of §3.4's fingerprint, with the request method
      # @param body [Hash] the arguments the fingerprint binds to
      def toll!(identity:, command:, name:, body:)
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

        PowGate.gate(
          identity: identity, command: command, method: request.request_method,
          verb: name, body: body, pow: pow
        )
      end

      # How a SUCCESS reaches the wire: the handler's payload, VERBATIM
      # (T-072 = C). No `ok`, no `kind`, no wrapper — the status line says
      # success and `output_schema` says what the shape is.
      #
      # ONE seam for every endpoint. Until the cutover this was overridden in
      # {VerbController} because `schema`/`pay` still answered 0.3's envelope
      # and the demo flow scripts read `.value` off them; they answer this
      # shape now, so the override is gone and there is nowhere left for the
      # two to disagree.
      def render_result(result)
        render_wire_body(result.to_payload, status: result.http_status)
      end

      # How an ERROR reaches the wire: an RFC 9457 problem document under its
      # own media type. The media type is the half a generic client reads —
      # `application/json` with a `title` field would be indistinguishable
      # from any other JSON — and the top-level `code` extension member is the
      # half an assistant branches on.
      def render_wire_error(error)
        render_wire_body(
          error.to_problem,
          status:       error.http_status,
          error:        error,
          content_type: Errors::PROBLEM_CONTENT_TYPE,
        )
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
