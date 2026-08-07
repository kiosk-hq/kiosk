# frozen_string_literal: true

module Kiosk
  module Server
    # Opt-in request-shape validation (slice-1 of the UNIFORM-VALIDATION
    # decision; closes K-479).
    #
    # When `Kiosk.configuration.validate_requests` is true, {WireController}
    # validates the proof(s) parsed from the `Kiosk-PoW` request header
    # (ADR-0022) against the VENDORED normative PoW schema BEFORE {PowGate.gate}
    # consumes them. The motivating failure (K-479): an agent submitted a
    # `{solutions:[…]}` shape instead of the schema shape
    # `{challenge:<echoed verbatim>,nonce:{indices,…}}`; {PowGate.extract_proofs}
    # silently returned `[]`, so the gate re-issued a fresh 402 on every retry —
    # an infinite loop with no diagnostic. With this on, a malformed proof raises
    # {Errors::BadRequest} carrying a hint that names the expected shape.
    #
    # == Scope (slice-1)
    #
    # ONLY the PoW proof(s) are validated, and ONLY when present. This is NOT the
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

      # Validate the proof(s) parsed from the `Kiosk-PoW` header against the
      # vendored PoW schema. The header parser flattens all accepted forms into
      # a flat array of `{challenge, nonce}` proofs, so each element is validated
      # as a single proof.
      #
      # @param proofs [Array<Hash>] the parsed proofs (already known non-empty)
      # @raise [Errors::BadRequest] with a shape hint when any proof does not
      #   conform to the normative schema
      # @raise [Errors::ConfigurationError] when json_schemer is not loadable
      def validate_proofs!(proofs)
        Array(proofs).each do |proof|
          errors = proof_schema.validate(normalize(proof)).to_a
          next if errors.empty?

          raise Errors::BadRequest.new(
            "malformed Kiosk-PoW proof",
            hint: POW_SHAPE_HINT,
          )
        end
      end

      # Human-readable description of the expected proof shape, echoed in the 400
      # hint (K-451 style — name the shape so the agent can self-correct).
      POW_SHAPE_HINT =
        "each Kiosk-PoW proof = " \
        "{challenge: <the challenge object from the 402, echoed verbatim>, " \
        "nonce: {indices: […], header_nonce?}}; the header carries one proof as " \
        "raw JSON or a JSON array of proofs. " \
        "Solve each challenge issued in the pow_required 402 and echo it back verbatim."

      # Memoized JSONSchemer::Schema for a SINGLE proof, built once from the
      # vendored file. The `Kiosk-PoW` header carries proof(s), which the parser
      # flattens to a list of `{challenge, nonce}` proofs — each validated
      # against the `proof` $def (not the top-level powField wrapper, which
      # existed for the retired body-pow `{proofs:[…]}` shape).
      def proof_schema
        @proof_schema ||= build_proof_schema
      end

      # Reset the memoized schema — test seam only (the schema is otherwise
      # immutable for the process lifetime).
      def reset!
        @proof_schema = nil
      end

      # ── internal ────────────────────────────────────────────────────────────

      # Build a schema rooted at the vendored file's `#/$defs/proof` while
      # keeping its sibling `$defs` in scope so the internal `$ref` to
      # `#/$defs/challenge` still resolves.
      def build_proof_schema
        require_schemer!
        doc = JSON.parse(File.read(POW_SCHEMA_PATH))
        root = doc.merge("$ref" => "#/$defs/proof")
        root.delete("oneOf")
        JSONSchemer.schema(root)
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
