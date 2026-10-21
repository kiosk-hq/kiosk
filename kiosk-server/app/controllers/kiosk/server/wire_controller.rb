# frozen_string_literal: true

require 'action_controller'
require 'action_dispatch/http/parameters'

module Kiosk
  module Server
    # The reserved `GET <endpoint>/schema` (public) and `POST <endpoint>/pay`,
    # and the base every WireController inherits its seams from.
    # Response (JSON): success is the handler's payload VERBATIM; an error
    # is an RFC 9457 problem document.
    class WireController < ::ActionController::API
      include VerbWire

      rescue_from Errors::Base, with: :render_wire_error

      # Touching `params` parses the body before any Kiosk code runs.
      rescue_from ::ActionDispatch::Http::Parameters::ParseError do
        render_wire_error(Errors.malformed_json(hint: BODY_HINT))
      end

      # No identity, no toll. A stale `?v=` still gets the current catalog,
      # with the short TTL.
      def schema
        render_public_document(
          SchemaDocument.json, version: SchemaDocument.digest, etag: SchemaDocument.etag
        )
      end

      def pay
        identity = resolve_identity!
        body     = parse_body!
        RequestValidation.validate_body!(body, exchange: 'POST <endpoint>/pay')

        execute_wire(command: :pay, args: body, identity: identity, name: 'pay')
      end

      private

      def execute_wire(**) = render_result(call_wire(**))
    end
  end
end
