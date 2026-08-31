# frozen_string_literal: true

# The wire surface. The engine draws the routes; hand-drawing them in the
# host's config/routes.rb remains the escape hatch.

require "action_controller"
require "action_dispatch/http/parameters"
require "cgi"
require "json"
require "kiosk/server/current_request"
require "kiosk/server/executor"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "kiosk/server/pow_gate"
require "kiosk/server/request_validation"
require "kiosk/server/schema_document"

module Kiosk
  module Server
    # The wire's own two RESERVED endpoints, and the base class every other
    # wire surface inherits its seams from:
    #
    #   GET  <endpoint>/schema   the catalog     — PUBLIC (T-094)
    #   POST <endpoint>/pay      settle an AP2 cart
    #
    # The two no longer share a request path. `schema` resolves no identity,
    # pays no toll and never reaches the {Executor}; it writes {SchemaDocument}
    # straight out under a public cache policy. Everything below the `pay`
    # action — parse, resolve, toll, execute, render — is the wire the rest of
    # this class and {VerbController} are about.
    #
    # Every OTHER verb is one endpoint per verb, served by {VerbController},
    # which subclasses this one. `POST <endpoint>/query` and
    # `POST <endpoint>/run` — 0.3's multiplexed pair — were DELETED at the 0.4
    # cutover (T-074 = A): no dedicated route is drawn for either name and no
    # tombstone stands in for one, so both fall through to {VerbController}
    # and answer the ordinary `404 verb_not_found` problem document — hint and all
    # — that any unregistered verb name gets (K-1112). One wire, one
    # conformance surface.
    #
    # Wire response (JSON): success is the handler's payload VERBATIM
    # ({Result#to_payload}), error is an RFC 9457 problem document
    # ({Errors::Base#to_problem}) under `application/problem+json`. Both seams
    # live HERE, not in the subclass, because after the cutover there is only
    # one answer shape — the two-shapes split that put them in
    # {VerbController} was the build-time intermediate, and it is over. A
    # paginating query is not a third shape either: since T-092 its page facts
    # ride the `Link` (RFC 8288) and `X-Total-Count` response headers and its
    # body is the same bare array — see {#add_pagination_headers}.
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

      # GET <endpoint>/schema — THE ONE PUBLIC ENDPOINT UNDER THE MOUNT
      # (T-094, Phil 2026-08-19).
      #
      # No identity, no toll, and it does not go through {Executor} at all: the
      # answer is {SchemaDocument}'s bytes, derived at boot, written straight
      # out. Three things went at once and they went together:
      #
      #   * THE BEARER GATE. The document holds verb names, descriptions,
      #     input/output schemas and examples — nothing per-agent and no
      #     secret. Gating it while `/.well-known/*` is wide open was an
      #     inconsistency that raised a question instead of answering one, and
      #     the decisive test is «does this need the backend, or is it a static
      #     file?»: it is a static file.
      #   * THE TOLL. `schema` was tolled as `:schema` so that ENUMERATING the
      #     catalogue cost something. That warrant died with the gate — a toll
      #     needs an identity to charge, and there is none here. `:schema`
      #     stopped being a policy verb altogether at K-804, when
      #     `/kiosk/openapi.json` — the one surface still paying that toll —
      #     went public for the same reasons; see {Executor::VERBS}.
      #   * `Vary: Authorization, Kiosk-PoW`. See {Headers.add_public_cache_policy}:
      #     a public document that varies on headers it does not read is one a
      #     shared cache can never reuse.
      #
      # The `?v=<digest>` fork is the cache-busting half, not a second
      # endpoint: same bytes either way, only the TTL differs. A `v` that does
      # NOT match still answers the CURRENT catalogue — an assistant holding a
      # stale link gets a true answer with a short TTL rather than a 404 it
      # cannot act on.
      def schema
        render_public_document(
          SchemaDocument.json, version: SchemaDocument.digest, etag: SchemaDocument.etag
        )
      end

      # POST <endpoint>/pay
      def pay
        run_command(:pay)
      end

      private

      # THE ONE PLACE A PUBLIC KIOSK DOCUMENT IS WRITTEN — the mirror of
      # {#render_wire_body}, and the two are deliberately not the same seam.
      #
      # Shared by `schema` here and by {OpenApiController#show}, which K-804
      # moved onto this path: two derived, identity-free descriptions of the
      # same registry, so anything either does about caching the other must do
      # too. Before K-804 the openapi document rendered through the WIRE seam,
      # and "give it the same treatment as `schema`" would have meant copying
      # four steps and the Rails workaround below into a second controller.
      #
      # @param json    [String] the serialized body, already JSON
      # @param version [String] the digest this URL's `?v=` is compared against
      # @param etag    [String] the STRONG entity tag, already quoted
      # @param content_type [String, nil] overrides `application/json`
      def render_public_document(json, version:, etag:, content_type: nil)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_public_cache_policy(
          response.headers, etag: etag, immutable: params[:v].to_s == version
        )

        if if_none_match?(etag)
          head :not_modified
        else
          options = { json: json, status: :ok }
          options[:content_type] = content_type if content_type
          render(**options)
        end

        # LAST, and it exists to undo one line of Rails.
        # `ActionController::Rendering#_set_vary_header` stamps `Vary: Accept`
        # on any render whose format was negotiated from the request's `Accept`
        # header — a sound default, and wrong here: these endpoints answer the
        # same bytes to every caller whatever they ask for, so the header
        # states a variance that does not exist and splits a shared cache by
        # Accept string for nothing. It fires only when the header is BLANK at
        # render time, so it cannot be pre-empted by setting the value we want,
        # which is none.
        response.headers.delete("Vary")
      end

      # RFC 9110 §13.1.2 — does the caller already hold these bytes? Written
      # out rather than taken from `fresh_when`, which hashes the validator it
      # is given: the ETag here IS the digest the discovery documents publish,
      # and an operator comparing the two by eye should find the same string.
      def if_none_match?(etag)
        raw = request.get_header("HTTP_IF_NONE_MATCH").to_s
        return false if raw.empty?
        return true  if raw.strip == "*"

        raw.split(",").any? { |tag| tag.strip.delete_prefix("W/") == etag }
      end

      # `pay`, the one reserved endpoint left on this path. Its wire NAME is
      # its command name, so the name travels to the request fingerprint
      # exactly as a per-verb call's does and its `"<METHOD> <verb>"` half
      # needs no special case. (`schema` shared this path until T-094 made it
      # public; it resolves no identity and pays no toll, so it has nothing
      # left to share.)
      def run_command(command)
        # parse_body! runs inside the action, so the rescue_from above covers
        # it: a malformed body raises Errors::BadRequest, which must render a
        # 400 problem document, not escape as an uncaught 500 (the same
        # parse-outside-rescue class fixed for
        # AuthController/KycAttestationController).
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
      #   as `verb:` and every shipped policy branches on those three symbols.
      # @param name [String] the WIRE name — the path segment. `pay` passes its
      #   own; a per-verb call passes the registered verb.
      def execute_wire(command:, args:, identity:, name:)
        # The request fingerprint: SHA256("<METHOD> <verb>\n<canonical args>").
        # The spec requires every challenge to be request-bound (§10, §15.2)
        # and leaves the digest itself to the operator; this is the engine's.
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
        # Kiosk::Handler`) is dispatched as a Rails sub-request built from these:
        # the identity lands in `env["kiosk.identity"]` (readable as
        # `kiosk_identity`), and the caller's headers/address are seeded from
        # this env. Block handlers registered the old way ignore both.
        #
        # `handler_headers` is the only thing that travels the other way
        # (K-823): {HandlerDispatch} writes the handler's own `Cache-Control`
        # into it, so §3.7.4's "an operator MAY relax a 200 to `private,
        # max-age=N`" is a permission an operator can actually exercise. It is
        # applied to the response BEFORE {#render_result}, which is what puts
        # it in front of {Headers.add_cache_policy} — the seam that keeps an
        # operator's own policy and, since K-823, refuses a shared-cache one.
        handler_headers = {}
        result = CurrentRequest.with(identity: identity, env: request.env,
                                     handler_headers: handler_headers) do
          Executor.call(
            kind:       command,
            args:       args,
            identity:   identity,
            connection: connection_for(identity),
            name:       name,
          )
        end
        handler_headers.each { |header, value| response.headers[header] = value }

        render_result(result)
      end

      # THE TOLL, on its own — the whole of what a caller pays before a Kiosk
      # surface answers, and nothing else.
      #
      # It is still its own method, one caller below, because the toll is one
      # idea and {#execute_wire} is four. It had a SECOND caller until K-804:
      # {OpenApiController} paid it with no {Executor} call behind it, tolled
      # as `:schema` so a second spelling of the catalog could not be read
      # around the price. That endpoint is public and untolled now, for the
      # same reasons `schema` is, and `:schema` is not a policy verb any more.
      #
      # @param identity [Kiosk::Identity] the resolved caller
      # @param command [Symbol] the gate/policy verb — one of {Executor::VERBS},
      #   because `reputation_factors` and `Policy#challenge_for` both take it
      #   as `verb:` and every shipped policy branches on those three symbols
      # @param name [String] the WIRE verb name, as it appears in the path —
      #   half of the request fingerprint, with the request method
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
        add_pagination_headers(result)
        render_wire_body(result.to_payload, status: result.http_status)
      end

      # PAGINATION LEAVES THE BODY (T-092, spec §8.4). The two facts a page
      # carries about itself are transport metadata, so they travel as response
      # headers and the body stays the bare array every other query answers:
      #
      #   Link: <…?limit=20&cursor=b2Zmc2V0OjIw>; rel="next"   RFC 8288
      #   X-Total-Count: 97
      #
      # `Link` is RFC 8288 (Web Linking) and is the reason a paginating query
      # no longer needs a body shape of its own. `X-Total-Count` is NOT a
      # standard — no RFC defines it — it is a de-facto convention adopted here
      # because it is widely used and immediately understood; the spec says so
      # in those words rather than citing an RFC that does not exist.
      #
      # WHEN EACH IS EMITTED, and both rules are about not stating something
      # untrue:
      #
      #   * `Link` — only on a TRUNCATED page. Its absence is what "this is the
      #     last page" means, which is the same signal an absent `next` field
      #     used to carry.
      #   * `X-Total-Count` — the number of rows MATCHING the query, across all
      #     pages. On a COMPLETE array answer that is the array's own length and
      #     the wire fills it in for every query, paginating or not. On a
      #     TRUNCATED page only the handler can know it, so it is emitted only
      #     when the handler passed `total:` to `render_kiosk_page`; defaulting
      #     to the payload length there would publish the PAGE size as the
      #     total, which is worse than saying nothing.
      #
      # Not cached, and that needs no special case: {Headers.add_cache_policy}
      # already puts `private, no-store` on every verb response (spec §3.7.4),
      # so a page cannot be served to a second caller, and §3.7.3 forbids
      # `public`/`s-maxage` on this plane outright. The CDN story T-094
      # shipped is for `GET <endpoint>/schema` alone.
      def add_pagination_headers(result)
        return unless result.kind == :rows

        if (cursor = result.next_cursor)
          add_link_header(next_page_link(cursor))
        end

        total = result.total
        total = result.payload.length if total.nil? && result.next_cursor.nil? &&
                                         result.payload.is_a?(::Array)
        response.headers["X-Total-Count"] = total.to_s unless total.nil?
      end

      # RFC 8288 §3: a `Link` field value is a comma-separated list, so an
      # operator that already set one keeps it and ours is appended. Ours is
      # always the only `rel="next"` — nothing else on this wire emits one.
      def add_link_header(value)
        existing = response.headers["Link"].to_s
        response.headers["Link"] = existing.empty? ? value : "#{existing}, #{value}"
      end

      # The next page's URI, built from THIS request: the same path and the
      # same arguments, with `cursor` replaced by the new opaque token.
      #
      # Built by editing the RAW query string rather than by re-serialising
      # parsed params, because a query's arguments include the bracket spellings
      # §8.1 defines (`amenity%5B%5D=`, `filter%5Bcity%5D=`) and a round trip
      # through a parser is a chance to hand back something the caller did not
      # send. Dropping the incoming `cursor` and appending the new one is the
      # whole edit.
      #
      # ABSOLUTE, not relative. RFC 8288 permits a URI-Reference resolved
      # against the request URI, and an assistant that follows the target
      # verbatim — which is the point of a Link header — is better served by a
      # URI it can fetch without a resolution step.
      def next_page_link(cursor)
        pairs = request.query_string.to_s.split("&").reject do |pair|
          pair.split("=", 2).first == "cursor"
        end
        pairs << "cursor=#{CGI.escape(cursor.to_s)}"

        %(<#{request.base_url}#{request.path}?#{pairs.join("&")}>; rel="next")
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
      # headers, the cache policy (spec §3.7 — `Vary: Authorization,
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
