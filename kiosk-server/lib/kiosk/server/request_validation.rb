# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/argument_decoder"

module Kiosk
  module Server
    # Request-shape validation of a submitted PoW proof. ON by default; an
    # operator turns it off with `c.validate_requests = false`.
    #
    # When `Kiosk.configuration.validate_requests` is true, {WireController}
    # validates the proof(s) parsed from the `Kiosk-PoW` request header
    # against the VENDORED normative PoW schema BEFORE {PowGate.gate}
    # consumes them. The motivating failure: an agent submitted a
    # `{solutions:[…]}` shape instead of the schema shape
    # `{challenge:<echoed verbatim>,nonce:{indices,…}}`; {PowGate.extract_proofs}
    # silently returned `[]`, so the gate re-issued a fresh 402 on every retry —
    # an infinite loop with no diagnostic. With this on, a malformed proof raises
    # {Errors::BadRequest} carrying a hint that names the expected shape.
    #
    # == Scope
    #
    # The flag covers the PoW proof(s) only, and only when present. This is NOT
    # the gate: a well-formed-but-forged proof still fails the real cryptographic
    # check inside {PowGate.gate}. That layer converts a SILENT re-challenge on a
    # malformed shape into a CLEAR 400.
    #
    # The second consumer is {.validate_arguments!}: a verb's own `input_schema`
    # validating the ARGUMENTS of a request to `<endpoint>/<verb-name>`, which is
    # what a REQUIRED `input_schema` buys — an executable input contract rather
    # than a published one. It runs on the COERCED arguments
    # ({ArgumentDecoder}) because json_schemer cannot check a query string's
    # `"4"` against `{type: "integer"}`.
    #
    # THAT SECOND CONSUMER IS NOT BEHIND THE FLAG. `validate_arguments!` is
    # UNCONDITIONAL on the per-verb wire ({VerbController#arguments_for}):
    # `input_schema` is REQUIRED on every verb and §8.1 item 5 makes the
    # operator coerce-then-validate before the handler sees an argument, so a
    # flag-gated check would be non-conformant with the flag off, and a typed
    # 400 for an invalid argument would exist on some origins and not others.
    # `validate_requests` keeps its own job below — the PoW-SHAPE check on
    # requests that carry a `Kiosk-PoW` header, on the wire and on the auth
    # plane. The verb's ANSWER is checked by the sibling {ResponseValidation},
    # behind its own `validate_responses` flag, which defaults OFF.
    #
    # THE VENDORED SCHEMA IS HELD AGAINST ITS NORMATIVE SOURCE, and this is
    # the file that has to say so, because {POW_SCHEMA_PATH} below is the copy.
    # `bin/check-spec-schemas` parses this copy and the published original
    # side by side — every published schema must have a copy and every copy a
    # published original — and the `$comment` provenance marker is the one
    # permitted difference. It compares only where the two repositories are
    # checked out beside each other, and says so and skips where they are not,
    # so the comparison is wired into the one CI job that guarantees the
    # sibling rather than into a job that would never compare anything.
    #
    # == Lazy require, real dependency
    #
    # `json_schemer` is a RUNTIME dependency of kiosk-server, not an optional
    # extra: §8.1 item 5 makes coerce-then-validate an operator obligation on
    # every per-verb call,
    # so an origin that cannot load a validator cannot serve a conformant wire
    # — and an install-time optional that fails on the first request is a lie
    # told at the wrong moment.
    #
    # It is still required LAZILY, inside this module, on the first validation,
    # and a missing gem is still an {Errors::ConfigurationError} naming it:
    # a vendored checkout without it should say so rather than LoadError at
    # boot.
    module RequestValidation
      module_function

      # Path to the VENDORED normative PoW schema (see the header $comment in the
      # file).
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

      # Validate one verb's ARGUMENTS against the `input_schema` it declares.
      #
      # Called from {VerbController} on the per-verb wire, AFTER
      # {ArgumentDecoder} has recovered the declared types (a query string
      # carries strings, and `"4"` is not an `integer` to any validator) and
      # BEFORE the handler runs.
      #
      # RESERVED NAMES. `limit` and `cursor` are always accepted
      # and never required to be declared, so a verb that does not declare them
      # never sees them here — otherwise getgrocery's `catalog`, whose schema is
      # the closed empty object `{additionalProperties: false, properties: {}}`,
      # would 400 on the very `?limit=` the pagination contract invites. A verb
      # that DOES declare one is validated against its own declaration, which is
      # the more specific statement.
      #
      # @param arguments [Hash] the decoded, COERCED arguments
      # @param input_schema [Hash, nil] the verb's declaration; nil skips
      # @param verb [String] the wire name, for the message
      # @raise [Errors::BadRequest] naming the parameter that failed
      # @raise [Errors::ConfigurationError] when json_schemer is not loadable
      def validate_arguments!(arguments, input_schema:, verb:)
        return if input_schema.nil?

        require_schemer!
        payload = normalize(arguments)
        exempt  = ArgumentDecoder::RESERVED.keys - declared_property_names(input_schema)
        payload = payload.reject { |name, _| exempt.include?(name) }

        errors = JSONSchemer.schema(normalize(input_schema)).validate(payload).to_a
        return if errors.empty?

        raise Errors::BadRequest.new(
          "#{verb}: #{errors.map { |error| error["error"] }.compact.join("; ")}",
          hint: "GET <endpoint>/schema publishes this verb's input_schema; the " \
                "arguments must satisfy it. `limit` and `cursor` are always accepted.",
        )
      end

      # The property names a declaration actually declares, as Strings. Used
      # only to decide whether a reserved name is exempt.
      def declared_property_names(input_schema)
        properties = ArgumentDecoder.fetch(input_schema, :properties)
        properties.is_a?(Hash) ? properties.keys.map(&:to_s) : []
      end

      # Human-readable description of the expected proof shape, echoed in the 400
      # hint — naming the shape is what lets the agent self-correct.
      #
      # THE NONCE IS NAMED RELATIVE TO `alg`, not absolutely. The
      # schema types the nonce conditionally on the challenge's algorithm, so a
      # hint that said «nonce: {indices…}» flatly would tell an operator running
      # a backend of their own to send a shape their own verifier does not want.
      POW_SHAPE_HINT =
        "each Kiosk-PoW proof = " \
        "{challenge: <the challenge object from the 402, echoed verbatim>, " \
        "nonce: <the solution, in the shape the challenge's `alg` defines — " \
        "for equihash, {indices: […], header_nonce?}>}; the header carries one proof as " \
        "raw JSON or a JSON array of proofs. " \
        "Solve each challenge issued in the pow_required 402 and echo it back verbatim."

      # Memoized JSONSchemer::Schema for a SINGLE proof, built once from the
      # vendored file. The `Kiosk-PoW` header carries proof(s), which the parser
      # flattens to a list of `{challenge, nonce}` proofs — each validated
      # against the `proof` $def rather than against the schema's own root,
      # whose `$ref` types the `powHeader`: one proof OR an array of them, a
      # choice this parser has already made by the time it gets here.
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
        # The message an operator reads while debugging must match the
        # gemspec: `json_schemer` is a RUNTIME dependency
        # (`add_dependency`, kiosk-server.gemspec), so reaching here does
        # not mean "you skipped an optional extra" — it means the dependency
        # that `gem install kiosk-server` resolves is not loadable in this
        # process, which is a broken install or a pruned bundle.
        raise Errors::ConfigurationError,
          "Kiosk::Server: validate_requests is enabled but the json_schemer gem " \
          "is not loadable. It is a RUNTIME dependency of kiosk-server " \
          "and should already be in your lockfile — check that the bundle is " \
          "installed and not pruned (`bundle install`, or `bundle list | grep " \
          "json_schemer`); add `gem \"json_schemer\"` to your Gemfile only if you " \
          "load kiosk-server outside Bundler."
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
