# frozen_string_literal: true

module Kiosk
  module Server
    # THE WIRE ERROR CONTRACT.
    #
    # The taxonomy is the closed, stable `code` VOCABULARY the spec's
    # "Error vocabulary" section publishes — {CODES}, a table, because the
    # contract is data: an assistant branches on the FLAT top-level `code` of
    # the problem document, which `error.code` is only the HANDLER-side
    # spelling of. A code exists precisely where an HTTP status alone cannot
    # carry the meaning (four codes share 403, three share 402). It is NOT a
    # class hierarchy mirroring Rails/HTTP: handler controllers express errors
    # in Rails' own idiom — `render json:, status:` or a Rails-registered
    # raise — and the mapping onto codes happens in one seam
    # ({HandlerMixin::InstanceMethods#kiosk_rescue_to_wire} +
    # {HandlerDispatch#decode}).
    #
    # Exception classes exist in two tiers:
    #
    #   * WIRE-ONLY codes — a bare status cannot name them, and gate-style
    #     internals raise them (some carry payload or a fixed hint). These
    #     stay.
    #   * RAILS-DUPLICATE codes — each merely restates what its bare HTTP
    #     status already says. New code must not raise them; they remain
    #     only because the gem's own protocol internals and some demo
    #     initializers still raise them.
    #
    # Each subclass declares CODE — the problem document's TOP-LEVEL `code`,
    # not `error.code`: a problem document is flat, and {Base#to_problem} below
    # is where that is decided — and HTTP_STATUS; both MUST agree with {CODES},
    # and the suite asserts it.
    module Errors
      # `code` → canonical HTTP status. `code`, not `error.code`: the keys of
      # this table are the problem document's flat top-level member. The closed
      # vocabulary: these seventeen codes ARE the spec's "Error vocabulary"
      # table — narrative (specification.html), formal (protocol.md §9) and
      # `problem.schema.json` all carry the same seventeen, `payment_failed`
      # among them since kiosk.tech a2f4089, `method_not_allowed` since the 0.4
      # per-verb wire, and `verb_not_found` + `module_not_served` since the
      # three-way split below.
      # Not a superset of the published table and not a subset of it; the two
      # are the same list, and a schema-validating client rejects anything
      # else. Adding a code here is a WIRE change: spec first (rule 1).
      #
      # `method_not_allowed` is a 0.4 addition and the reason it exists is
      # the per-verb wire: once the HTTP METHOD carries the read/write
      # semantics, `GET <endpoint>/<action-name>` is a resource that EXISTS
      # and refuses this method, which is a different fact from "no such
      # verb" and RFC 9110 §15.5.6 already has a status for it. Adding to a
      # closed vocabulary is spec-first, so the code is here because the
      # spec's own table carries it.
      #
      # THREE CODES ANSWER "IT IS NOT HERE". A single `not_found` would carry
      # all three at once, and `code` is the ONE field the spec tells an
      # assistant to branch on, so an assistant told «not found» for a hotel
      # nobody serves re-reads the catalogue and retries — right for one of the
      # three, a wasted round trip and a wrong report to the human for the
      # others:
      #
      #   * `verb_not_found` (404) — no verb by that NAME is registered here.
      #     Raised by {Queries}/{Actions} when the registry has no entry, BEFORE
      #     any handler runs. Recovery: re-read the catalogue.
      #   * `not_found` (404) — the verb exists and an ARGUMENT addressed
      #     something absent (spec §9.1 rule 2). Recovery: none; say so.
      #   * `module_not_served` (501) — this ORIGIN does not serve the optional
      #     module the path reaches. Recovery: fall back to what you would do at
      #     an operator that never offered it.
      #
      # The first two share 404 on purpose — the spec argues it: one 404's target
      # resource is the verb's own path, the other's is the entity an argument
      # named, and this table already puts four codes on 403 and three on 402 for
      # the same reason. `module_not_served` is 501 because the path is PUBLISHED
      # and correct (§4.3 requires all six auth URLs of an operator that serves
      # no binding at all), so a 404 there would be a false statement about the
      # URL — and RFC 9110 §15.6.2 is the status for "does not support the
      # functionality required to fulfill the request".
      CODES = {
        "bad_request"            => 400,
        "unauthenticated"        => 401,
        "pow_required"           => 402,
        "payment_setup_required" => 402,
        "payment_failed"         => 402,
        "forbidden"              => 403,
        "rls_denied"             => 403,
        "spending_cap_exceeded"  => 403,
        "kyc_required"           => 403,
        "verb_not_found"         => 404,
        "not_found"              => 404,
        "method_not_allowed"     => 405,
        "conflict"               => 409,
        "quota_exceeded"         => 429,
        "action_failed"          => 500,
        "internal_error"         => 500,
        "module_not_served"      => 501,
      }.freeze

      # RFC 9457 `title` per code — "a short, human-readable summary of the
      # problem type" that, per §3.1.3, "SHOULD NOT change from occurrence to
      # occurrence". So it is a CONSTANT of the code, never of the incident:
      # the incident-specific sentence is `detail` (the `message`). One entry
      # per {CODES} key, asserted by the suite, because a problem document
      # whose title is missing is not a problem document.
      TITLES = {
        "bad_request"            => "Malformed request",
        "unauthenticated"        => "Not authenticated",
        "pow_required"           => "Proof-of-work required",
        "payment_setup_required" => "Payment setup required",
        "payment_failed"         => "Payment failed",
        "forbidden"              => "Forbidden",
        "rls_denied"             => "Row-level security denied the statement",
        "spending_cap_exceeded"  => "Spending cap exceeded",
        "kyc_required"           => "KYC attestation required",
        "verb_not_found"         => "No such verb",
        "not_found"              => "Not found",
        "method_not_allowed"     => "Method not allowed",
        "conflict"               => "State conflict",
        "quota_exceeded"         => "Quota exceeded",
        "action_failed"          => "Action failed",
        "internal_error"         => "Internal error",
        "module_not_served"      => "Module not served",
      }.freeze

      # The RFC 9457 `type` namespace. A problem document's `type` is
      # `PROBLEM_TYPE_BASE + code`, so the closed vocabulary IS the type
      # space: one URI per code, minted nowhere else, never parameterised.
      #
      # It is an IDENTIFIER, not a document locator. RFC 9457 §3.1.1 only
      # ENCOURAGES dereferencing ("when dereferenced, it might provide
      # human-readable documentation"); the normative documentation for every
      # code is the spec's own error-vocabulary table. Publishing a page per
      # code on kiosk.tech is a site-side follow-up, and because the URI is
      # fixed here it can be done later without touching the wire.
      #
      # An AI assistant MUST branch on the `code` extension member, never on
      # this URI: the code is the contract, the URI is its name.
      PROBLEM_TYPE_BASE = "https://kiosk.tech/problems/"

      # The RFC 9457 media type. Every error on the per-verb wire is served
      # with it — that is what makes the document a problem document to a
      # generic client rather than just JSON that happens to have a `title`.
      PROBLEM_CONTENT_TYPE = "application/problem+json"

      # @param code [String] a {CODES} key
      # @return [String] the problem `type` URI naming it
      def self.problem_type(code) = "#{PROBLEM_TYPE_BASE}#{code}"

      # @param code [String] a {CODES} key
      # @return [String] the problem `title` for it, falling back to the code
      #   itself so an unlisted code still yields a well-formed document.
      def self.problem_title(code) = TITLES.fetch(code, code)

      # HTTP status → the ONE code a bare status carries by itself. This is
      # the whole Rails-native mapping: a handler's rendered status, or the
      # status Rails' own `config.action_dispatch.rescue_responses` assigns
      # a raised exception, answers the wire with this code.
      #
      # Deliberate absences, never to be "completed":
      #   402 — three codes share it (pow_required / payment_setup_required /
      #         payment_failed); guessing would put the wrong one on the
      #         wire. A handler meaning a specific 402 names the code.
      #   500 — action_failed vs internal_error is the same ambiguity, and an
      #         unhandled exception must keep its {Executor} `action_failed`
      #         wrap.
      #   501 — `module_not_served` is a claim about the ORIGIN's module set,
      #         and a raise from inside a handler cannot establish it: by the
      #         time a handler runs, the module IS being served. Rails maps
      #         `ActionController::NotImplemented` to 501 and that means
      #         something else entirely, so this status is NOT mapped and an
      #         operator meaning `module_not_served` raises it by name.
      #
      # 404 IS PRESENT EVEN THOUGH TWO CODES SHARE IT, and that is not an
      # oversight in the rule above. Only ONE of the two is reachable from a
      # Rails-native raise: `verb_not_found` comes from the registry
      # lookup in {Queries}/{Actions}, which raises its own class before any
      # handler is entered, so the only 404 a handler's `RecordNotFound` can
      # mean is the addressed-thing-is-absent `not_found` — which is exactly
      # what a lookup miss IS. 402 and 500 are ambiguous at the raise site;
      # 404 is not.
      # 422 answers `bad_request`: Rails' validation-failure status, one wire
      # code (the canonical status stays 400 — {CODES} decides what is
      # rendered).
      STATUS_CODES = {
        400 => "bad_request",
        401 => "unauthenticated",
        403 => "forbidden",
        404 => "not_found",
        405 => "method_not_allowed",
        409 => "conflict",
        422 => "bad_request",
        429 => "quota_exceeded",
      }.freeze
      # Cap on how many registered names a verb-not-found hint enumerates before it
      # truncates with "…". Keeps the problem document small on a large surface
      # while still naming enough for an assistant to spot a near-miss typo.
      MAX_HINT_NAMES = 20
      # Plural of each wire-name kind, for the hint below. Only reachable when
      # NOTHING is registered for that kind — which is a rare enough path that
      # a naive `"#{verb}s"` can say "No querys are registered" for a long time
      # unnoticed: it is wrong for exactly one of the two words this vocabulary
      # has.
      HINT_PLURALS = { "query" => "queries", "action" => "actions" }.freeze

      # Builds the `hint` for a {VerbNotFound} raised on an unknown query/action name.
      # Names the available names for that verb so an assistant that mistyped
      # (`listings` for `browse_listings`) can recover WITHOUT first fetching the
      # schema, and always appends the schema pointer for the full descriptions.
      # The names are already public via GET .../schema, so listing them leaks
      # nothing an authenticated agent couldn't already read.
      #
      #   Errors.unknown_name_hint("listings", "query", %w[browse_listings listing_detail])
      #   # => "unknown query 'listings'. Available: browse_listings, listing_detail. " \
      #   #    "Call GET .../schema for the full catalog."
      #
      # @param name  [#to_s]         the unknown name the caller supplied
      # @param verb  [String]        "query" or "action"
      # @param names [Array<String>] the registered names for that verb (sorted)
      def self.unknown_name_hint(name, verb, names)
        listed  = names.first(MAX_HINT_NAMES).join(", ")
        listed += ", …" if names.size > MAX_HINT_NAMES
        available = if names.empty?
                      "No #{HINT_PLURALS.fetch(verb, "#{verb}s")} are registered."
                    else
                      "Available: #{listed}."
                    end
        "unknown #{verb} '#{name}'. #{available} Call GET .../schema for the full catalog."
      end

      # ── THE TWO MALFORMED-REQUEST SENTENCES, BUILT HERE AND NOWHERE ELSE ────
      #
      # Neither a Ruby exception's `message` nor a parser's is ours to publish,
      # so neither is ever spliced into the problem document's `detail`. Spliced,
      # `KeyError#message` answers `POST /kiosk/auth/register` with an empty
      # object as `missing field: key not found: :public_key` — Ruby symbol and
      # all, on the FIRST call an assistant makes — and the json gem answers a
      # body that is not JSON as `invalid JSON body: unexpected token 'notjson'
      # at line 1 column 1`, which is the json gem's wording and moves when the
      # parser does.
      #
      # `missing field: <name>` is the house sentence: the seven demos answer an
      # absent argument with it (`WireArguments.missing`, held in lockstep
      # across three of them by bin/check-demo-copies) and it is the one an
      # assistant's error handling matches on. The controller that raises it
      # words its own query-parameter refusal `missing public_key query
      # parameter` a hundred lines away, in the same register.
      #
      # A detail says WHAT is wrong in this repository's own words; anything the
      # caller needs in order to retry goes in `hint`, which is where the
      # position information a parser message carried belongs if a site wants it.

      # `missing field: <name>` — the field, never the exception.
      #
      # @param err  [KeyError, #to_s] the rescued `KeyError`, or the field name
      # @param hint [String, nil]
      def self.missing_field(err, hint: nil)
        name = err.is_a?(::KeyError) ? key_of(err) : err
        return BadRequest.new("missing field: #{name}", hint: hint) if name

        # `raise KeyError, "…"` by hand sets no key, and `KeyError#key` raises
        # ArgumentError when asked. Say so in plain words rather than falling
        # back to `message`, which is the sentence this method exists to keep
        # off the wire.
        BadRequest.new("request is missing a required field", hint: hint)
      end

      # @return [String, nil] the absent key's name, or nil when the error
      #   carries none.
      def self.key_of(err)
        err.key.to_s
      rescue ::ArgumentError
        nil
      end

      # The recovery sentence for a body that did not parse. One string, so the
      # three controllers that answer this cannot word it three ways.
      MALFORMED_JSON_HINT = "the request body must be a single well-formed JSON object"

      # `invalid JSON body` — the whole detail. The parser's own message is
      # deliberately dropped: it names Ruby's json gem rather than this
      # protocol, and a caller that sent something which is not JSON does not
      # need a byte offset to find that out.
      #
      # @param hint [String, nil] defaults to {MALFORMED_JSON_HINT}; a site with
      #   a narrower one (the verb wire's arguments-vs-query-string split)
      #   passes it.
      def self.malformed_json(hint: MALFORMED_JSON_HINT)
        BadRequest.new("invalid JSON body", hint: hint)
      end

      # ── THE SENTENCE A RAILS-NATIVE RAISE ANSWERS WITH ──────────────────────
      #
      # {HandlerMixin::InstanceMethods#kiosk_rescue_to_wire} is the seam that
      # turns a raise Rails knows a status for — `params.require`'s
      # `ParameterMissing`, Active Record's `RecordNotFound`, whatever the host
      # registered in `config.action_dispatch.rescue_responses` — into a wire
      # code, with NO Kiosk classes in the handler.
      #
      # Same class as the two sentences above: the exception's own text is not
      # ours, it moves when a dependency is upgraded, and on a path a caller can
      # reach it can echo the caller's own bytes back out. Rendered into the
      # sub-dispatch envelope, a `params.require(:sku)` handler would answer a
      # 400 with `"detail":"param is missing or the value is empty or invalid:
      # sku"` — actionpack's own sentence, verbatim. So the seam publishes OUR
      # sentence for the code it decided, and the exception's own class, message
      # and backtrace go to the operator's log ({FailureLog}) — which is where
      # {Executor}'s two 500 paths already send theirs.
      #
      # WHAT THIS DOES NOT SILENCE, because it is the reason the redaction is
      # safe to make wholesale: an operator who MEANS to speak to the agent has
      # two documented routes that never reach this code, and both are exercised
      # by the handler-mixin suite. Rendering the envelope explicitly
      # (`render json: { error: { code:, message:, hint: } }, status:`) never
      # raises, so this seam never sees it; and raising a {Base} is re-raised
      # untouched on `kiosk_rescue_to_wire`'s first line. This route exists ONLY
      # for exceptions the operator did not author — that is its stated purpose —
      # so redacting it silences a library, not an operator.
      #
      # THE ONE COST, PRICED RATHER THAN HIDDEN: a host that registers its OWN
      # exception class in `rescue_responses` and raises it with a sentence
      # meant for the agent loses that sentence here. It is undocumented usage,
      # nothing distinguishes a host's class from a library's in that table
      # (Rails' own doc for it is about libraries), the two routes above remain
      # open to it, and a library sentence on an unauthenticated path is the
      # larger risk. The suite pins BOTH halves — the loss, and the recovery.
      #
      # One entry per {STATUS_CODES} value, asserted by the suite: a code that
      # seam can decide and this table cannot word would fall back to a
      # `KeyError` at request time.

      # The DETAIL, as a clause the verb's name opens. Says what the origin did,
      # in this protocol's words, and nothing about which library was involved.
      RESCUED_DETAILS = {
        "bad_request"        => "rejected the request as malformed",
        "unauthenticated"    => "requires a credential this request did not carry",
        "forbidden"          => "refused the request",
        "not_found"          => "found no such record",
        "method_not_allowed" => "does not accept the request as sent",
        "conflict"           => "refused the request as conflicting with current state",
        "quota_exceeded"     => "refused the request because a quota is exhausted",
      }.freeze

      # The HINT: what the CALLER does next. Addressed to the assistant, so
      # none of these mentions the operator's log — the diagnostic half of this
      # refusal is not the caller's business and it could not act on it anyway.
      RESCUED_HINTS = {
        "bad_request"        => "check the arguments against this verb's input_schema — " \
                                "GET .../schema publishes it.",
        "unauthenticated"    => "present a valid access token for this origin and retry.",
        "forbidden"          => "this principal may not make this call; retrying it unchanged " \
                                "will be refused again.",
        "not_found"          => "an argument names something this origin does not have; " \
                                "re-read it from a query before retrying.",
        "method_not_allowed" => "a query is GET .../<query-name> and an action is " \
                                "POST .../<action-name>; GET .../schema says which each verb is.",
        "conflict"           => "the state moved under you; re-read it with a query and retry " \
                                "with what it says.",
        "quota_exceeded"     => "the operator sets this quota; wait before retrying.",
      }.freeze

      # The sub-dispatch envelope's `error` object for a Rails-native raise.
      #
      # Returns the HASH rather than an {Base}: the seam renders it into the
      # internal `{ok:, error:}` protocol between a handler and
      # {HandlerDispatch}, which decodes it and builds the {Base} itself. The
      # wording lives here anyway, with the other two sentences, so there stays
      # exactly one file to read to know what this engine says when it refuses.
      #
      # @param code [String] a {STATUS_CODES} value
      # @param verb [String, nil] the wire name this dispatch arrived under
      # @return [Hash] `{code:, message:, hint:}`
      def self.rescued_wire(code, verb: nil)
        subject = verb.nil? || verb.to_s.empty? ? "this verb" : "verb #{verb.to_s.inspect}"
        { code:    code,
          message: "#{subject} #{RESCUED_DETAILS.fetch(code)}",
          hint:    RESCUED_HINTS.fetch(code) }
      end

      # Base class. `rescue Kiosk::Server::Errors::Base` catches every Kiosk
      # error without leaking unrelated StandardErrors.
      class Base < StandardError
        CODE        = "internal_error"
        HTTP_STATUS = 500

        attr_reader :hint

        def initialize(message = nil, hint: nil)
          super(message)
          @hint = hint
        end

        def code        = self.class.const_get(:CODE)
        def http_status = self.class.const_get(:HTTP_STATUS)

        # Fields BEYOND `code`/`message`/`hint` that belong in the answer —
        # {PowRequired}'s `challenges`, a handler's own rendered extras
        # carried through by {WireError}. One hook, so the two renderings
        # below cannot disagree about what an error carries.
        def extensions = {}

        # Response headers this error requires. RFC 9110 §15.5.6 makes `Allow`
        # MANDATORY on a 405, so it cannot be left to the caller to remember;
        # `WWW-Authenticate` is added at the render seam because it is built
        # from configuration ({WireController#www_authenticate_for}).
        def response_headers = {}

        # RFC 9457 problem document — THE error shape, served as
        # `application/problem+json`. It is the only error shape any endpoint
        # serves.
        #
        # THE CLOSED VOCABULARY SURVIVES TWICE OVER, deliberately:
        #
        #   * `type` is {Errors.problem_type} — one URI per code, so the
        #     vocabulary is also the RFC's type space and a generic
        #     problem-aware client sees a real problem type rather than a
        #     single catch-all URI.
        #   * `code` is an RFC 9457 EXTENSION MEMBER (§3.2) carrying the bare
        #     token. This is the branch point: an assistant reads `code` and
        #     matches the same seventeen strings {CODES} declares. Branching on
        #     `type` would mean string-surgery on a URI, so the spec forbids
        #     it and this member is why it can.
        #
        # `message` becomes the RFC's `detail` (the incident-specific
        # sentence); `hint` and `challenges` stay extension members under
        # their own names, so `hint`'s remediation contract is untouched.
        # `instance` is deliberately NOT emitted: it would restate the request
        # URL the client just dialed, and RFC 9457 makes it OPTIONAL.
        #
        # The branch point is `code`, not `error.code`: a problem document is
        # flat, so the member sits at the top level.
        def to_problem
          {
            type:   Errors.problem_type(code),
            title:  Errors.problem_title(code),
            status: http_status,
            detail: message,
            code:   code,
            hint:   hint,
          }.merge(extensions).compact
        end
      end

      # A wire error named by CODE, not by class. The carrier the handler seam
      # raises when a rendered non-2xx has to travel to the wire
      # as a coded envelope: the code is data (any {CODES} key), the status
      # comes from the table, and `extra:` carries additional envelope
      # fields (a rendered `challenges`, say) through verbatim. One class for
      # the whole vocabulary — this is what "taxonomy as contract, not as
      # hierarchy" looks like at the raise site.
      class WireError < Base
        def initialize(message = nil, code:, hint: nil, extra: nil)
          code = code.to_s
          unless CODES.key?(code)
            raise ArgumentError,
              "unknown wire code #{code.inspect} — the vocabulary is Errors::CODES, closed by the spec"
          end

          super(message, hint: hint)
          @wire_code = code
          @extra     = extra || {}
        end

        def code        = @wire_code
        def http_status = CODES.fetch(@wire_code)
        def extensions  = @extra
      end

      # ── RAILS-DUPLICATE CODES ─────────────────────────────────────────
      # Each of the five classes below restates what its bare HTTP status
      # already says, i.e. exactly the parallel framework Kiosk deliberately
      # does not have. Do not raise them from new code — render the status
      # (handlers) or raise {WireError} / the Rails exception. They survive
      # only because the gem's own protocol internals and some demo
      # initializers still raise them. `quota_exceeded` has NO class here and
      # needs none: the code is live on the wire — getgrocery and skooti refuse
      # a fourth outstanding KYC intake with it — but through
      # `OperationResult.refused`, which is the operator-side spelling, so the
      # engine raises it nowhere.

      # DUPLICATE of a bare 400. Malformed body, unknown verb, missing
      # required arg.
      class BadRequest < Base
        CODE        = "bad_request"
        HTTP_STATUS = 400
      end

      # DUPLICATE of a bare 401. Missing or invalid identity — no token,
      # expired token, wrong issuer.
      class Unauthenticated < Base
        CODE        = "unauthenticated"
        HTTP_STATUS = 401
      end

      # DUPLICATE of a bare 403. Identity valid but not permitted.
      class Forbidden < Base
        CODE        = "forbidden"
        HTTP_STATUS = 403
      end

      # DUPLICATE of a bare 404. An ARGUMENT addressed a resource that does not
      # exist -- spec §9.1 rule 2, and that is the whole of what it means: an
      # unknown VERB NAME is {VerbNotFound} below, because an assistant recovers
      # from the two differently and `code` is the only field the spec lets it
      # branch on.
      class NotFound < Base
        CODE        = "not_found"
        HTTP_STATUS = 404
      end

      # No verb by that NAME is registered at this origin. The path's last
      # segment matched nothing in either registry, so nothing about
      # what this operator can DO has been established -- a different verb may
      # well do the thing the caller wanted, which is why this is not
      # {NotFound}. `hint` carries the registered names
      # ({Errors.unknown_name_hint}), so a mistyped `listings` for
      # `browse_listings` self-corrects without a catalogue round-trip.
      #
      # WIRE-ONLY even though 404 is a bare status: the status alone cannot
      # name it, because the OTHER 404 in this vocabulary is what a
      # bare 404 means ({STATUS_CODES}). Raised only by {Queries}/{Actions},
      # before any handler is entered.
      class VerbNotFound < Base
        CODE        = "verb_not_found"
        HTTP_STATUS = 404
      end

      # The verb EXISTS at this path but not for this method — `GET` at an
      # action's name, `POST` at a query's. New in 0.4 and meaningless before
      # it: under the 0.3 name-dispatch wire a query and an action were the
      # same POST endpoint distinguished by a body field, so getting them the
      # wrong way round could only ever be "unknown query".
      #
      # `allow` is REQUIRED — RFC 9110 §15.5.6 makes the `Allow` header
      # mandatory on a 405, and a caller who has to remember it eventually
      # will not, so the error carries it and the render seam emits it.
      class MethodNotAllowed < Base
        CODE        = "method_not_allowed"
        HTTP_STATUS = 405

        # @return [String] the `Allow` header value — the method this verb
        #   does accept ("GET" for a query, "POST" for an action).
        attr_reader :allow

        def initialize(message = nil, allow:, hint: nil)
          super(message, hint: hint)
          @allow = allow.to_s
        end

        def response_headers = { "Allow" => allow }
      end

      # DUPLICATE of a bare 409. Request collides with existing state — e.g.
      # a mandate already processed (unique violation on a per-principal
      # signed-id index, the idempotency anchor).
      class Conflict < Base
        CODE        = "conflict"
        HTTP_STATUS = 409
      end

      # ── WIRE-ONLY CODES ───────────────────────────────────────────────
      # These codes are why the vocabulary exists — a bare status cannot name
      # them. The classes stay because gate-style internals raise them; a
      # handler can just as well RENDER the code
      # (`render json: {error: {code: "rls_denied", …}}, status: :forbidden`)
      # and the seam carries the code into the problem document verbatim.
      # `error.code` is the HANDLER-side spelling; what travels is the flat
      # top-level `code` of an RFC 9457 document.

      # Row-level-security rejected the request. HTTP 403 but a distinct CODE
      # from `forbidden` so agents can tell «policy excluded this row» from
      # «you can't reach this endpoint».
      class RLSDenied < Base
        CODE        = "rls_denied"
        HTTP_STATUS = 403
      end

      # The acting assistant's per-assistant spending cap would be exceeded by
      # this charge. HTTP 403 — a policy refusal the agent cannot pay
      # its way past; the human must raise the cap. Distinct CODE from Forbidden
      # so an agent can tell «over your spending limit» from «you can't do this»,
      # and distinct from the 402 gates (which mean «do X then retry»). Enforced
      # in the pay path BEFORE the irreversible capture.
      class SpendingCapExceeded < Base
        CODE        = "spending_cap_exceeded"
        HTTP_STATUS = 403
      end

      # The acting agent has not completed the KYC attestation(s) this Action
      # requires — either no attestation on file, or the stored attributes do
      # not include every required boolean. HTTP 403 — a policy refusal the
      # agent clears by submitting a KYC attestation carrying the missing
      # attributes to POST /agents/kyc, then retrying. Distinct CODE from
      # Forbidden so an agent can tell «complete KYC» from «you can't do this».
      class KycRequired < Base
        CODE        = "kyc_required"
        HTTP_STATUS = 403
      end

      # Action raised an unhandled exception. HTTP 500 — but a distinct CODE
      # from `internal_error` (the two share the status, which is exactly why
      # 500 is absent from {STATUS_CODES}): «the operator's handler blew up»
      # is actionable differently from «the platform did».
      class ActionFailed < Base
        CODE        = "action_failed"
        HTTP_STATUS = 500
      end

      # The principal has no saved payment method on file and must complete a
      # SetupIntent (or equivalent PSP onboarding) before this charge can
      # proceed.  The assistant should call `payment_setup` to obtain the
      # setup URL and have the human complete it.  HTTP 402.
      class PaymentSetupRequired < Base
        CODE        = "payment_setup_required"
        HTTP_STATUS = 402

        def initialize(message = "payment setup required",
                       hint: "call payment_setup to obtain a card setup link")
          super(message, hint: hint)
        end
      end

      # The PSP declined or could not complete the charge (card_declined,
      # authentication_required, insufficient_funds, a processor timeout, …).
      # HTTP 402 — the charge did not settle; the assistant may retry after the
      # human corrects the payment method (payment_setup). Distinct CODE from
      # payment_setup_required (which means «no card on file yet») and from the
      # PoW 402. The adapter translates its PSP-specific error into a human-safe
      # message BEFORE it reaches here, so no raw PSP internals leak to the
      # wire. In the published error vocabulary since kiosk.tech a2f4089 —
      # the spec's own table, not an extension of it — and specified there as
      # the one 402 that is NOT a gate: no `challenges`, and deliberately no
      # `WWW-Authenticate`, so a client MUST branch on `code`.
      class PaymentFailed < Base
        CODE        = "payment_failed"
        HTTP_STATUS = 402

        def initialize(message = "payment failed",
                       hint: "the charge did not settle; verify via my_orders before retrying")
          super(message, hint: hint)
        end
      end

      # Proof-of-work required — the provider's reputation policy demands one or
      # more PoW challenges for this request. The client solves EACH challenge
      # (each has a distinct salt — no amortisation, that is the N×PoW
      # anti-abuse dial) and re-sends the SAME request with the proof(s) in the
      # `Kiosk-PoW` request header as raw JSON. HTTP 402.
      class PowRequired < Base
        CODE        = "pow_required"
        HTTP_STATUS = 402

        # The full set of independent challenges the client must solve.
        attr_reader :challenges

        def initialize(challenges:)
          super("proof-of-work required")
          @challenges = challenges
        end

        # Embed the challenges in the answer — a top-level extension member of
        # the problem document, which is the only error shape any endpoint has
        # served since the cutover — so the client can solve them without a
        # second round-trip.
        def extensions = { challenges: challenges }
      end

      # This ORIGIN does not serve the OPTIONAL MODULE the request reaches --
      # account binding (spec §6), payment (§11) or KYC
      # (§12). HTTP 501, and the spec argues the status at length: the path is
      # PUBLISHED and correct -- §4.3 requires all six auth URLs even of an
      # operator that serves no binding -- so a 404 would be a false statement
      # about the URL, and it would put this case on the same status as the two
      # genuine 404s, recreating the ambiguity the three-way split removes. No
      # 4xx means it: `forbidden` is identity-scoped while this refusal is
      # ORIGIN-WIDE and true of an anonymous caller too, `410 Gone` asserts the
      # capability once existed, `405` is method-scoped. RFC 9110 §15.6.2 is the
      # status for "does not support the functionality required to fulfill the
      # request", and makes it cacheable by default -- right, because this is a
      # property of the origin rather than of the request.
      #
      # `message` NAMES THE MODULE: it becomes the problem document's `detail`,
      # and it is the only thing distinguishing "no binding here" from "no
      # payments here" to a human reading the answer.
      #
      # NOT a misconfiguration report. {ConfigurationError} below is for a
      # feature the operator INTENDED to serve and wired up wrong; this is the
      # wire's answer for a capability the origin simply does not offer, and a
      # caller cannot tell an operator's intent from the outside anyway.
      class ModuleNotServed < Base
        CODE        = "module_not_served"
        HTTP_STATUS = 501
      end

      # Misconfiguration of the Kiosk::Server integration — raised at
      # gate-call time (not load time) so a misconfigured optional feature
      # doesn't prevent the server from booting.
      class ConfigurationError < StandardError; end
    end
  end
end
