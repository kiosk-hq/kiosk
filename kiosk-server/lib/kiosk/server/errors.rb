# frozen_string_literal: true

module Kiosk
  module Server
    # Exception classes the {Executor} raises and {ExecController}
    # serialises to error envelopes per design spec §5.2 (exit codes 0/2/3/4/5/6).
    #
    # Each subclass declares three constants used by the wire envelope and
    # HTTP serialisation:
    #
    #   CODE        — stable string for the JSON envelope's `error.code`
    #   EXIT_CODE   — CLI exit code per spec §5.2
    #   HTTP_STATUS — HTTP response status the controller renders
    module Errors
      # Base class. `rescue Kiosk::Server::Errors::Base` catches every Kiosk
      # error without leaking unrelated StandardErrors.
      class Base < StandardError
        CODE        = "internal_error"
        EXIT_CODE   = 6
        HTTP_STATUS = 500

        attr_reader :hint, :query_id

        def initialize(message = nil, hint: nil, query_id: nil)
          super(message)
          @hint     = hint
          @query_id = query_id
        end

        def code        = self.class.const_get(:CODE)
        def exit_code   = self.class.const_get(:EXIT_CODE)
        def http_status = self.class.const_get(:HTTP_STATUS)

        # Envelope shape per spec §5.2 — structured body with `code`,
        # `hint`, `query_id`. nil fields are dropped for compactness.
        def to_envelope
          {
            ok: false,
            error: {
              code:     code,
              message:  message,
              hint:     hint,
              query_id: query_id,
            }.compact,
          }
        end
      end

      # Bad client request — malformed body, unknown verb, missing required
      # arg, SQL syntax error.  Exit 2.
      class BadRequest < Base
        CODE        = "bad_request"
        EXIT_CODE   = 2
        HTTP_STATUS = 400
      end

      # Missing or invalid identity — no token, expired token, wrong issuer.
      # Exit 3.
      class Unauthenticated < Base
        CODE        = "unauthenticated"
        EXIT_CODE   = 3
        HTTP_STATUS = 401
      end

      # Identity valid but not permitted at the resource level. Exit 3.
      class Forbidden < Base
        CODE        = "forbidden"
        EXIT_CODE   = 3
        HTTP_STATUS = 403
      end

      # Row-level-security rejected the request. Exit 4 (distinct from
      # Forbidden so agents can tell «policy excluded this row» from
      # «you can't reach this endpoint»).
      class RLSDenied < Base
        CODE        = "rls_denied"
        EXIT_CODE   = 4
        HTTP_STATUS = 403
      end

      # Resource lookup failed — unknown table, unknown Action name. Exit 2.
      class NotFound < Base
        CODE        = "not_found"
        EXIT_CODE   = 2
        HTTP_STATUS = 404
      end

      # Request collides with existing state — e.g. a mandate already
      # processed (unique violation on a per-principal signed-id index, the
      # idempotency anchor). Exit 2, HTTP 409.
      class Conflict < Base
        CODE        = "conflict"
        EXIT_CODE   = 2
        HTTP_STATUS = 409
      end

      # Rate limit hit. Exit 5.
      class QuotaExceeded < Base
        CODE        = "quota_exceeded"
        EXIT_CODE   = 5
        HTTP_STATUS = 429
      end

      # Action raised an unhandled exception. Exit 6.
      class ActionFailed < Base
        CODE        = "action_failed"
        EXIT_CODE   = 6
        HTTP_STATUS = 500
      end

      # Proof-of-work required — the provider's reputation policy demands a
      # PoW challenge for this request. The client must solve the challenge and
      # re-send the request with `pow: {challenge:, nonce:}`. HTTP 402.
      class PowRequired < Base
        CODE        = "pow_required"
        EXIT_CODE   = 2
        HTTP_STATUS = 402

        attr_reader :challenge

        def initialize(challenge:)
          super("proof-of-work required")
          @challenge = challenge
        end

        # Override: embed the challenge in the error envelope so the client
        # can solve it without a second round-trip.
        def to_envelope
          { ok: false, error: { code: code, message: message, challenge: challenge } }
        end
      end

      # Misconfiguration of the Kiosk::Server integration — raised at
      # gate-call time (not load time) so a misconfigured optional feature
      # doesn't prevent the server from booting.
      class ConfigurationError < StandardError; end
    end
  end
end
