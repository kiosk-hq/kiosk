# frozen_string_literal: true

module Kiosk
  module Server
    # Opt-in request-shape validation (slice-1 of the UNIFORM-VALIDATION
    # decision; closes K-479).
    #
    # When `Kiosk.configuration.validate_requests` is true, {WireController}
    # validates a PRESENT `pow` field against the VENDORED normative PoW schema
    # BEFORE {PowGate.gate} consumes it. The motivating failure (K-479): an agent
    # submitted `pow: {solutions:[…]}` instead of the schema shape
    # `pow: {proofs:[{challenge:<echoed verbatim>,nonce:{indices,…}}]}`;
    # {PowGate.extract_proofs} silently returned `[]`, so the gate re-issued a
    # fresh 402 on every retry — an infinite loop with no diagnostic. With this
    # on, a malformed pow raises {Errors::BadRequest} carrying a hint that names
    # the expected shape.
    #
    # == Scope (slice-1)
    #
    # ONLY the `pow` field is validated, and ONLY when present. This is NOT the
    # gate: a well-formed-but-forged proof still fails the real cryptographic
    # check inside {PowGate.gate}. This layer converts a SILENT re-challenge on a
    # malformed shape into a CLEAR 400. The fuller uniform-validation layer
    # (query/run bodies, envelope, auth schemas, response-conformance CI, vendored
    # schema sync-check) is v0.5 / T-045.
    #
    # == Lazy / optional dependency
    #
    # `json_schemer` is NOT a runtime dependency of kiosk-server (the core stays
    # dep-light). It is required lazily, inside this module, only on the first
    # validation. If `validate_requests` is on but the gem is not loadable, a
    # {Errors::ConfigurationError} naming the gem is raised — fail-loud rather
    # than silently skipping validation.
    module RequestValidation
      module_function

      # Path to the VENDORED normative PoW schema (see the header $comment in the
      # file; sync-check is T-045).
      POW_SCHEMA_PATH = File.expand_path("schemas/pow.schema.json", __dir__)

      # Validate a PRESENT `pow` value against the vendored PoW schema.
      #
      # @param pow [Object] the split-out pow value (already known non-nil/non-empty)
      # @raise [Errors::BadRequest] with a shape hint when the pow does not
      #   conform to the normative schema
      # @raise [Errors::ConfigurationError] when json_schemer is not loadable
      def validate_pow!(pow)
        errors = pow_schema.validate(normalize(pow)).to_a
        return if errors.empty?

        raise Errors::BadRequest.new(
          "malformed pow field",
          hint: POW_SHAPE_HINT,
        )
      end

      # Human-readable description of the expected pow shape, echoed in the 400
      # hint (K-451 style — name the shape so the agent can self-correct).
      POW_SHAPE_HINT =
        "expected pow.proofs[] where each proof = " \
        "{challenge: <the challenge object from the 402, echoed verbatim>, " \
        "nonce: {indices: […], header_nonce?}} " \
        "(a single {challenge, nonce} proof is also accepted). " \
        "Solve each challenge issued in the pow_required 402 and echo it back verbatim."

      # Memoized JSONSchemer::Schema built once from the vendored file.
      def pow_schema
        @pow_schema ||= build_schema
      end

      # Reset the memoized schema — test seam only (the schema is otherwise
      # immutable for the process lifetime).
      def reset!
        @pow_schema = nil
      end

      # ── internal ────────────────────────────────────────────────────────────

      def build_schema
        require_schemer!
        JSONSchemer.schema(JSON.parse(File.read(POW_SCHEMA_PATH)))
      end

      def require_schemer!
        require "json_schemer"
      rescue LoadError
        raise Errors::ConfigurationError,
          "Kiosk::Server: validate_requests is enabled but the json_schemer gem " \
          "is not loadable. Add `gem \"json_schemer\"` to your app's Gemfile " \
          "(it is an OPTIONAL dependency — kiosk-server does not require it unless " \
          "request validation is turned on)."
      end

      # json_schemer wants string keys and JSON-native values; the wire body is
      # parsed with `symbolize_names: true`, so recursively stringify keys before
      # validating. Non-Hash/Array values pass through unchanged.
      def normalize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = normalize(v) }
        when Array
          obj.map { |v| normalize(v) }
        else
          obj
        end
      end
    end
  end
end
