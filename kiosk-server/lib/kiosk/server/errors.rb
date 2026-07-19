# frozen_string_literal: true

module Kiosk
  module Server
    # Exception classes the {Executor} raises and {WireController}
    # serialises to error envelopes — see the response-envelope section of
    # the spec.
    #
    # Each subclass declares two constants used by the wire envelope and
    # HTTP serialisation:
    #
    #   CODE        — stable string for the JSON envelope's `error.code`
    #   HTTP_STATUS — HTTP response status the controller renders
    module Errors
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

      # Bad client request — malformed body, unknown verb, missing required
      # arg, SQL syntax error.
      class BadRequest < Base
        CODE        = "bad_request"
        HTTP_STATUS = 400
      end

      # Missing or invalid identity — no token, expired token, wrong issuer.
      class Unauthenticated < Base
        CODE        = "unauthenticated"
        HTTP_STATUS = 401
      end

      # Identity valid but not permitted at the resource level.
      class Forbidden < Base
        CODE        = "forbidden"
        HTTP_STATUS = 403
      end

      # Row-level-security rejected the request. HTTP 403 but a distinct CODE
      # from Forbidden so agents can tell «policy excluded this row» from
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

      # Resource lookup failed — unknown table, unknown Action name.
      class NotFound < Base
        CODE        = "not_found"
        HTTP_STATUS = 404
      end

      # Request collides with existing state — e.g. a mandate already
      # processed (unique violation on a per-principal signed-id index, the
      # idempotency anchor). HTTP 409.
      class Conflict < Base
        CODE        = "conflict"
        HTTP_STATUS = 409
      end

      # Rate limit hit. No raiser in the shipped executor yet — kiosk-server
      # ships no quota/rate-limit enforcement and the spec documents no
      # quota_exceeded/429 error code. The class exists to reserve the CODE +
      # HTTP_STATUS for a future quota gate and to keep the error hierarchy
      # complete; the exercised quota-denial path lives in kiosk-test-support
      # (NullExecutor + the be_quota_exceeded / assert_quota_exceeded helpers).
      class QuotaExceeded < Base
        CODE        = "quota_exceeded"
        HTTP_STATUS = 429
      end

      # Action raised an unhandled exception.
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

      # Proof-of-work required — the provider's reputation policy demands one or
      # more PoW challenges for this request. The client solves EACH challenge
      # (each has a distinct salt — no amortisation, that is the N×PoW
      # anti-abuse dial) and re-sends the SAME request with
      # `pow: {proofs: [{challenge:, nonce:}, ...]}`. HTTP 402.
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
