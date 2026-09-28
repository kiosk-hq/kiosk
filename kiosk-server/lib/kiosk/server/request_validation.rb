# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/argument_decoder"

module Kiosk
  module Server
    # Request-shape validation against the schemas the spec publishes. ON by
    # default; an operator turns it off with `c.validate_requests = false`.
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
    # The same flag covers {.validate_body!}: the RESERVED plane's JSON request
    # bodies — register, login, claim, unlink, the KYC attestation and `pay` —
    # each held to the object §17 publishes for it. Those bodies are the wire an
    # assistant meets BEFORE it holds a token, and until this layer existed the
    # only thing reading them was a `fetch` per member, so a wrong-TYPED member
    # travelled into a verifier and came back as whatever that verifier happened
    # to raise. §16.3 anchor 1 asks an operator to validate against the
    # schemas; this is the engine doing it. The two `/oauth/*` requests are
    # form-encoded and §17 publishes no schema for them, so they are not here.
    #
    # == Scope
    #
    # The PoW arm covers the proof(s) only, and only when present. This is NOT
    # the gate: a well-formed-but-forged proof still fails the real cryptographic
    # check inside {PowGate.gate}. That layer converts a SILENT re-challenge on a
    # malformed shape into a CLEAR 400.
    #
    # The body arm is a SHAPE check in the same sense: a `signed` that is a
    # string of the right type but not a valid possession proof still fails
    # {PopVerifier}, and a `cart_mandate_jws` that parses still has to survive
    # the mandate chain. What it converts is a TYPE error deep in a verifier
    # into a 400 naming the member at the edge.
    #
    # The third consumer is {.validate_arguments!}: a verb's own `input_schema`
    # validating the ARGUMENTS of a request to `<endpoint>/<verb-name>`, which is
    # what a REQUIRED `input_schema` buys — an executable input contract rather
    # than a published one. It runs on the COERCED arguments
    # ({ArgumentDecoder}) because json_schemer cannot check a query string's
    # `"4"` against `{type: "integer"}`.
    #
    # THAT THIRD CONSUMER IS NOT BEHIND THE FLAG. `validate_arguments!` is
    # UNCONDITIONAL on the per-verb wire ({VerbController#arguments_for}):
    # `input_schema` is REQUIRED on every verb and §8.1 item 5 makes the
    # operator coerce-then-validate before the handler sees an argument, so a
    # flag-gated check would be non-conformant with the flag off, and a typed
    # 400 for an invalid argument would exist on some origins and not others.
    # The reserved plane is the other side of that line: §16.3 anchor 1 says
    # an operator SHOULD validate a wire object against its schema, so an
    # origin that turns the flag off is still conformant — which is why the
    # body arm sits behind `validate_requests` and the argument arm does not.
    # The verb's ANSWER is checked by the sibling {ResponseValidation},
    # behind its own `validate_responses` flag, which defaults OFF.
    #
    # THE VENDORED SCHEMAS ARE HELD AGAINST THEIR NORMATIVE SOURCES, and this
    # is the file that has to say so, because {SCHEMA_DIR} below holds the
    # copies. `bin/check-spec-schemas` parses each copy and the published
    # original side by side — every published schema must have a copy and every
    # copy a published original — and the `$comment` provenance marker is the
    # one permitted difference. It compares only where the two repositories are
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

      # The VENDORED normative schemas (see the header $comment in each file).
      SCHEMA_DIR = File.expand_path("schemas", __dir__)

      # Path to the VENDORED normative PoW schema.
      POW_SCHEMA_PATH = File.join(SCHEMA_DIR, "pow.schema.json")

      # RESERVED-PLANE REQUEST BODY => the published object that types it.
      #
      # The key is the wire exchange, spelled as the caller dials it, because
      # that is what the 400 has to name. The value is `<file>#<pointer>` into
      # the vendored copy of the schema §17 lists for that object — never a
      # restatement of the members, so an object whose shape moves upstream
      # moves here with the copy `bin/check-spec-schemas` holds.
      #
      # This table IS the list. `POST /oauth/device_authorization` and
      # `POST /oauth/token` are absent because they are form-encoded and §17
      # publishes no schema for them; `GET <endpoint>/auth/challenge` is absent
      # because it carries no body at all.
      BODY_SCHEMAS = {
        "POST <endpoint>/auth/register" => "auth.schema.json#/$defs/credentialRequest",
        "POST <endpoint>/auth/login"    => "auth.schema.json#/$defs/credentialRequest",
        "POST <endpoint>/auth/claim"    => "binding.schema.json#/$defs/claimRequest",
        "POST <endpoint>/auth/unlink"   => "binding.schema.json#/$defs/unlinkRequest",
        "POST <endpoint>/agents/kyc"    => "kyc.schema.json#/$defs/request",
        "POST <endpoint>/pay"           => "mandates.schema.json#/$defs/payRequest",
      }.freeze

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

      # Validate a RESERVED-plane JSON request body against the object §17
      # publishes for it, when `validate_requests` is on.
      #
      # `exchange` is a key of {BODY_SCHEMAS} and doubles as what the 400
      # names, so the caller reads back the endpoint it dialed. The refusal is
      # `bad_request` — §9's vocabulary already carries "malformed request:
      # unparseable body, missing fields", and a shape failure is exactly
      # that, so no code is added to a closed enum.
      #
      # AN ABSENT MEMBER KEEPS THE WIRE'S OWN SENTENCE. `missing field: signed`
      # is what this plane has always answered, {Errors.missing_field} is its
      # one builder, and `wire_wording_spec.rb` holds it — so a `required`
      # failure is routed there rather than given the validator's phrasing. A
      # wrong TYPE is the half that had no sentence at all, and gets one here.
      #
      # @param body [Hash] the parsed body
      # @param exchange [String] a {BODY_SCHEMAS} key
      # @raise [Errors::BadRequest] naming the member that failed
      # @raise [Errors::ConfigurationError] when json_schemer is not loadable
      def validate_body!(body, exchange:)
        return unless Kiosk.configuration.validate_requests

        pointer = BODY_SCHEMAS.fetch(exchange)
        errors  = wire_schema(pointer).validate(normalize(body)).to_a
        return if errors.empty?

        absent = missing_member(errors, body)
        raise Errors.missing_field(absent, hint: body_hint(pointer)) if absent

        raise Errors::BadRequest.new(
          "#{exchange}: #{errors.map { |error| error["error"] }.compact.join("; ")}",
          hint: body_hint(pointer),
        )
      end

      # The first REQUIRED member the body does not carry, or nil when every
      # failure is about something else. Read off the body rather than out of
      # the validator's message, so the name is the schema's spelling.
      def missing_member(errors, body)
        return nil unless errors.any? { |error| error["type"] == "required" }

        present = normalize(body).keys
        errors.filter_map { |error| error["details"]&.fetch("missing_keys", nil) }
              .flatten.find { |name| !present.include?(name) }
      end

      # Where a caller reads the object its body has to satisfy.
      def body_hint(pointer)
        file, fragment = pointer.split("#", 2)
        "the body must satisfy #{file} #{fragment}, published at " \
          "https://kiosk.tech/spec/schemas/#{file}."
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

      # A compiled schema rooted at one `$def` of a vendored file, with that
      # file's sibling `$defs` still in scope so an internal `$ref` resolves.
      # Memoized per pointer: the documents are immutable for the process
      # lifetime and compiling one per request would be the layer's whole cost.
      #
      # @param pointer [String] `<file>#<json-pointer>`, a {BODY_SCHEMAS} value
      def wire_schema(pointer)
        @wire_schemas ||= {}
        @wire_schemas[pointer] ||= begin
          require_schemer!
          file, fragment = pointer.split("#", 2)
          doc = JSON.parse(File.read(File.join(SCHEMA_DIR, file)))
          JSONSchemer.schema(doc.merge("$ref" => "##{fragment}"))
        end
      end

      # Reset the memoized schemas — test seam only (they are otherwise
      # immutable for the process lifetime).
      def reset!
        @proof_schema = nil
        @wire_schemas = nil
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
