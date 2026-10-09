# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/argument_decoder"

module Kiosk
  module Server
    # Validates requests against the vendored normative schemas: `Kiosk-PoW`
    # proofs and reserved-plane bodies behind `c.validate_requests` (§16.3), and
    # verb arguments against their `input_schema` always (§8.1 item 5).
    module RequestValidation
      module_function

      SCHEMA_DIR = File.expand_path("schemas", __dir__)

      POW_SCHEMA_PATH = File.join(SCHEMA_DIR, "pow.schema.json")

      # RESERVED-PLANE REQUEST BODY => the published object that types it.
      # The `/oauth/*` requests are form-encoded and have no schema.
      BODY_SCHEMAS = {
        "POST <endpoint>/auth/register" => "auth.schema.json#/$defs/credentialRequest",
        "POST <endpoint>/auth/login"    => "auth.schema.json#/$defs/credentialRequest",
        "POST <endpoint>/auth/claim"    => "binding.schema.json#/$defs/claimRequest",
        "POST <endpoint>/auth/unlink"   => "binding.schema.json#/$defs/unlinkRequest",
        "POST <endpoint>/agents/kyc"    => "kyc.schema.json#/$defs/request",
        "POST <endpoint>/pay"           => "mandates.schema.json#/$defs/payRequest",
      }.freeze

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

      # A missing member keeps the wire's own `missing field:` sentence.
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

      def missing_member(errors, body)
        return nil unless errors.any? { |error| error["type"] == "required" }

        present = normalize(body).keys
        errors.filter_map { |error| error["details"]&.fetch("missing_keys", nil) }
              .flatten.find { |name| !present.include?(name) }
      end

      def body_hint(pointer)
        file, fragment = pointer.split("#", 2)
        "the body must satisfy #{file} #{fragment}, published at " \
          "https://kiosk.tech/spec/schemas/#{file}."
      end

      # Runs on the coerced arguments. An undeclared `limit`/`cursor` is exempt:
      # those names are always accepted.
      def validate_arguments!(arguments, input_schema:, verb:)
        return if input_schema.nil?

        require_schemer!
        payload = normalize(arguments)
        exempt  = ArgumentDecoder::RESERVED.keys - declared_property_names(input_schema)
        payload = payload.reject { |name, _| exempt.include?(name) }

        errors = JSONSchemer.schema(normalize(input_schema)).validate(payload).to_a
        return if errors.empty?

        spellings = errors.filter_map do |error|
          next unless error["type"] == "format"

          spelling = ArgumentDecoder::FORMAT_SPELLINGS[error.dig("schema", "format")]
          "#{error["data_pointer"].delete_prefix("/")}: send #{spelling}. " if spelling
        end
        raise Errors::BadRequest.new(
          "#{verb}: #{errors.map { |error| error["error"] }.compact.join("; ")}",
          hint: "#{spellings.uniq.join}GET <endpoint>/schema publishes this verb's input_schema; the " \
                "arguments must satisfy it. `limit` and `cursor` are always accepted.",
        )
      end

      def declared_property_names(input_schema)
        properties = ArgumentDecoder.fetch(input_schema, :properties)
        properties.is_a?(Hash) ? properties.keys.map(&:to_s) : []
      end

      # The nonce is named relative to `alg`: its shape depends on the backend.
      POW_SHAPE_HINT =
        "each Kiosk-PoW proof = " \
        "{challenge: <the challenge object from the 402, echoed verbatim>, " \
        "nonce: <the solution, in the shape the challenge's `alg` defines — " \
        "for equihash, {indices: […], header_nonce?}>}; the header carries one proof as " \
        "raw JSON or a JSON array of proofs. " \
        "Solve each challenge issued in the pow_required 402 and echo it back verbatim."

      def proof_schema
        @proof_schema ||= build_proof_schema
      end

      # Rooted at one `$def`, with the file's other `$defs` in scope.
      def wire_schema(pointer)
        @wire_schemas ||= {}
        @wire_schemas[pointer] ||= begin
          require_schemer!
          file, fragment = pointer.split("#", 2)
          doc = JSON.parse(File.read(File.join(SCHEMA_DIR, file)))
          JSONSchemer.schema(doc.merge("$ref" => "##{fragment}"))
        end
      end

      def reset!
        @proof_schema = nil
        @wire_schemas = nil
      end

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
          "is not loadable. It is a RUNTIME dependency of kiosk-server " \
          "and should already be in your lockfile — check that the bundle is " \
          "installed and not pruned (`bundle install`, or `bundle list | grep " \
          "json_schemer`); add `gem \"json_schemer\"` to your Gemfile only if you " \
          "load kiosk-server outside Bundler."
      end

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
