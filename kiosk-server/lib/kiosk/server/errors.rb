# frozen_string_literal: true

module Kiosk
  module Server
    # The wire error contract: the closed `code` vocabulary and the problem
    # document (RFC 9457) every refusal is rendered as.
    module Errors
      # The wire's seventeen refusal codes and their HTTP status (spec §9). Adding one is a spec change first.
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

      # RFC 9457 `title`: constant per code; the incident goes in `detail`.
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

      # An identifier, not a page: clients branch on `code`, never on this URI.
      PROBLEM_TYPE_BASE = "https://kiosk.tech/problems/"

      PROBLEM_CONTENT_TYPE = "application/problem+json"

      def self.problem_type(code) = "#{PROBLEM_TYPE_BASE}#{code}"

      def self.problem_title(code) = TITLES.fetch(code, code)

      # The code a bare status (rendered, or from Rails' `rescue_responses`) maps to.
      # 402 and 500 are absent: several codes share each, so a handler names the code.
      # 501 is absent: `module_not_served` is raised by name, never inferred.
      # 404 is `not_found`: `verb_not_found` is raised by the registry before any handler runs.
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
      MAX_HINT_NAMES = 20
      HINT_PLURALS = { "query" => "queries", "action" => "actions" }.freeze

      #   Errors.unknown_name_hint("listings", "query", %w[browse_listings listing_detail])
      #   # => "unknown query 'listings'. Available: browse_listings, listing_detail. " \
      #   #    "Call GET .../schema for the full catalog."
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

      # The two malformed-request sentences are built here and nowhere else;
      # an exception's or a parser's own message never reaches `detail`.

      # @param err [KeyError, #to_s] the rescued `KeyError`, or the field name
      def self.missing_field(err, hint: nil)
        name = err.is_a?(::KeyError) ? key_of(err) : err
        return BadRequest.new("missing field: #{name}", hint: hint) if name

        # A hand-raised KeyError carries no key.
        BadRequest.new("request is missing a required field", hint: hint)
      end

      def self.key_of(err)
        err.key.to_s
      rescue ::ArgumentError
        nil
      end

      MALFORMED_JSON_HINT = "the request body must be a single well-formed JSON object"

      def self.malformed_json(hint: MALFORMED_JSON_HINT)
        BadRequest.new("invalid JSON body", hint: hint)
      end

      # What a Rails-native raise answers with: our sentence for the decided code.
      # The exception's own text goes to the operator's log, never to the wire.
      # One entry per {STATUS_CODES} value.

      RESCUED_DETAILS = {
        "bad_request"        => "rejected the request as malformed",
        "unauthenticated"    => "requires a credential this request did not carry",
        "forbidden"          => "refused the request",
        "not_found"          => "found no such record",
        "method_not_allowed" => "does not accept the request as sent",
        "conflict"           => "refused the request as conflicting with current state",
        "quota_exceeded"     => "refused the request because a quota is exhausted",
      }.freeze

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

      # @return [Hash] `{code:, message:, hint:}` for the handler sub-dispatch envelope
      def self.rescued_wire(code, verb: nil)
        subject = verb.nil? || verb.to_s.empty? ? "this verb" : "verb #{verb.to_s.inspect}"
        { code:    code,
          message: "#{subject} #{RESCUED_DETAILS.fetch(code)}",
          hint:    RESCUED_HINTS.fetch(code) }
      end

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

        # Problem-document members beyond `code`/`message`/`hint`.
        def extensions = {}

        def response_headers = {}

        # `code` is a top-level extension member (RFC 9457 §3.2): the one field a client branches on.
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

      # A wire error named by its code rather than its class; `extra:` passes through to the document.
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

      class BadRequest < Base
        CODE        = "bad_request"
        HTTP_STATUS = 400
      end

      class Unauthenticated < Base
        CODE        = "unauthenticated"
        HTTP_STATUS = 401
      end

      class Forbidden < Base
        CODE        = "forbidden"
        HTTP_STATUS = 403
      end

      # An argument names something absent (§9.1 rule 2); an unknown verb is {VerbNotFound}.
      class NotFound < Base
        CODE        = "not_found"
        HTTP_STATUS = 404
      end

      # No verb by that name is registered; the hint lists the ones that are.
      class VerbNotFound < Base
        CODE        = "verb_not_found"
        HTTP_STATUS = 404
      end

      # The verb exists but not for this HTTP method.
      class MethodNotAllowed < Base
        CODE        = "method_not_allowed"
        HTTP_STATUS = 405

        attr_reader :allow

        def initialize(message = nil, allow:, hint: nil)
          super(message, hint: hint)
          @allow = allow.to_s
        end

        def response_headers = { "Allow" => allow }
      end

      class Conflict < Base
        CODE        = "conflict"
        HTTP_STATUS = 409
      end

      class RLSDenied < Base
        CODE        = "rls_denied"
        HTTP_STATUS = 403
      end

      # The acting assistant's spending cap would be exceeded; checked before capture.
      class SpendingCapExceeded < Base
        CODE        = "spending_cap_exceeded"
        HTTP_STATUS = 403
      end

      class KycRequired < Base
        CODE        = "kyc_required"
        HTTP_STATUS = 403
      end

      # The operator's handler raised; `internal_error` is the platform's own failure.
      class ActionFailed < Base
        CODE        = "action_failed"
        HTTP_STATUS = 500
      end

      class PaymentSetupRequired < Base
        CODE        = "payment_setup_required"
        HTTP_STATUS = 402

        def initialize(message = "payment setup required",
                       hint: "call payment_setup to obtain a card setup link")
          super(message, hint: hint)
        end
      end

      # The charge did not settle. The adapter supplies a human-safe message, never the PSP's.
      class PaymentFailed < Base
        CODE        = "payment_failed"
        HTTP_STATUS = 402

        def initialize(message = "payment failed",
                       hint: "the charge did not settle; verify via my_orders before retrying")
          super(message, hint: hint)
        end
      end

      class PowRequired < Base
        CODE        = "pow_required"
        HTTP_STATUS = 402

        attr_reader :challenges

        def initialize(challenges:)
          super("proof-of-work required")
          @challenges = challenges
        end

        def extensions = { challenges: challenges }
      end

      # This origin does not serve the optional module the path reaches (§6, §11, §12).
      # `message` names the module.
      class ModuleNotServed < Base
        CODE        = "module_not_served"
        HTTP_STATUS = 501
      end

      # Raised when an optional feature is called, not at boot.
      class ConfigurationError < StandardError; end
    end
  end
end
