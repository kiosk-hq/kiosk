# frozen_string_literal: true

module Kiosk
  module Server
    # THE WIRE ERROR CONTRACT (T-054, K-495 sub-decision 4).
    #
    # The taxonomy is the closed, stable `error.code` VOCABULARY the spec's
    # "Error vocabulary" section publishes — {CODES}, a table, because the
    # contract is data: an assistant branches on the code string, and a code
    # exists precisely where an HTTP status alone cannot carry the meaning
    # (four codes share 403, three share 402). It is NOT a class hierarchy
    # mirroring Rails/HTTP: handler controllers express errors in Rails'
    # own idiom — `render json:, status:` or a Rails-registered raise — and
    # the mapping onto codes happens in one seam
    # ({HandlerMixin::InstanceMethods#kiosk_rescue_to_wire} +
    # {HandlerDispatch#decode}).
    #
    # Exception classes exist in two tiers, each annotated below with its
    # T-054 audit verdict:
    #
    #   * WIRE-ONLY codes — a bare status cannot name them, and gate-style
    #     internals raise them (some carry payload or a fixed hint). These
    #     stay.
    #   * RAILS-DUPLICATE codes — each merely restates what its bare HTTP
    #     status already says. New code must not raise them; they remain
    #     only for the gem's own pre-T-054 internals and the demo
    #     initializers T-057 migrates.
    #
    # Each subclass declares CODE (the envelope's `error.code`) and
    # HTTP_STATUS; both MUST agree with {CODES}, and the suite asserts it.
    module Errors
      # `error.code` → canonical HTTP status. The closed vocabulary: these
      # fourteen codes ARE the spec's "Error vocabulary" table — narrative
      # (specification.html), formal (protocol.md §9) and `error.schema.json`
      # all carry the same fourteen, `payment_failed` among them since
      # kiosk.tech a2f4089. Not a superset of the published table and not a
      # subset of it; the two are the same list, and a schema-validating
      # client rejects anything else. Adding a code here is a WIRE change:
      # spec first (rule 1).
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
        "not_found"              => 404,
        "conflict"               => 409,
        "quota_exceeded"         => 429,
        "action_failed"          => 500,
        "internal_error"         => 500,
      }.freeze

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
      # 422 answers `bad_request`: Rails' validation-failure status, one wire
      # code (the canonical status stays 400 — {CODES} decides what is
      # rendered).
      STATUS_CODES = {
        400 => "bad_request",
        401 => "unauthenticated",
        403 => "forbidden",
        404 => "not_found",
        409 => "conflict",
        422 => "bad_request",
        429 => "quota_exceeded",
      }.freeze
      # Cap on how many registered names a not-found hint enumerates before it
      # truncates with "…". Keeps the error envelope small on a large surface
      # while still naming enough for an assistant to spot a near-miss typo.
      MAX_HINT_NAMES = 20

      # Builds the `hint` for a NotFound raised on an unknown query/action name.
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
        available = names.empty? ? "No #{verb}s are registered." : "Available: #{listed}."
        "unknown #{verb} '#{name}'. #{available} Call GET .../schema for the full catalog."
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

        # Envelope shape — structured body with `code`, `message`, `hint`.
        # nil fields are dropped for compactness.
        def to_envelope
          {
            ok: false,
            error: {
              code:    code,
              message: message,
              hint:    hint,
            }.compact,
          }
        end
      end

      # A wire error named by CODE, not by class (T-054). The carrier the
      # handler seam raises when a rendered non-2xx has to travel to the wire
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

        def to_envelope
          { ok: false, error: { code: code, message: message, hint: hint }.merge(@extra).compact }
        end
      end

      # ── RAILS-DUPLICATE CODES ─────────────────────────────────────────
      # T-054 audit verdict: each of the five classes below restates what
      # its bare HTTP status already says, i.e. exactly the parallel
      # framework K-495 killed. Do not raise them from new code — render the
      # status (handlers) or raise {WireError} / the Rails exception. They
      # survive only because the gem's own protocol internals and the
      # pre-T-057 demo initializers still raise them; QuotaExceeded, which
      # nothing raised, is already gone (the code stays reserved in {CODES}).

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

      # DUPLICATE of a bare 404. Unknown table, unknown Action name.
      class NotFound < Base
        CODE        = "not_found"
        HTTP_STATUS = 404
      end

      # DUPLICATE of a bare 409. Request collides with existing state — e.g.
      # a mandate already processed (unique violation on a per-principal
      # signed-id index, the idempotency anchor).
      class Conflict < Base
        CODE        = "conflict"
        HTTP_STATUS = 409
      end

      # ── WIRE-ONLY CODES ───────────────────────────────────────────────
      # T-054 audit verdict: these codes are why the vocabulary exists — a
      # bare status cannot name them. The classes stay because gate-style
      # internals raise them; a handler can just as well RENDER the code
      # (`render json: {ok: false, error: {code: "rls_denied", …}},
      # status: :forbidden`) and the seam carries it verbatim.

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
      # message BEFORE it reaches here, so no raw PSP internals leak to the wire
      # (K-545). In the published error vocabulary since kiosk.tech a2f4089 —
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
      # `Kiosk-PoW` request header as raw JSON (ADR-0022). HTTP 402.
      class PowRequired < Base
        CODE        = "pow_required"
        HTTP_STATUS = 402

        # The full set of independent challenges the client must solve.
        attr_reader :challenges

        def initialize(challenges:)
          super("proof-of-work required")
          @challenges = challenges
        end

        # Override: embed the challenges in the error envelope so the client
        # can solve them without a second round-trip.
        def to_envelope
          { ok: false, error: { code: code, message: message, challenges: challenges } }
        end
      end

      # Misconfiguration of the Kiosk::Server integration — raised at
      # gate-call time (not load time) so a misconfigured optional feature
      # doesn't prevent the server from booting.
      class ConfigurationError < StandardError; end
    end
  end
end
