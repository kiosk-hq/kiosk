# frozen_string_literal: true

require 'json'

module Kiosk
  module Server
    # The gates of a call in the protocol, in order: identity (401), the arguments
    # (400), the caller's timezone (400) and the toll (402). Then the call runs
    # inside a session. {WireController} and every controller that includes
    # {Kiosk::Handler} serve the protocol with them.
    module VerbWire
      include WireRendering

      BODY_HINT = "an action's arguments are a JSON object in the request body; " \
                  "a query's are in the query string."

      private

      def resolve_identity!
        identity = IdentityResolution.resolve(request)
        raise Errors::AccessTokenRefused if identity.nil?

        identity
      end

      # Query string for a query, JSON body for an action; never both.
      def arguments_for(command, name, descriptor)
        args = if command == :query
                 ArgumentDecoder.decode(request.query_string, input_schema: descriptor[:input_schema])
               else
                 parse_body!
               end

        # Unconditional: §8.1 item 5 makes coerce-then-validate a MUST.
        RequestValidation.validate_arguments!(
          args, input_schema: descriptor[:input_schema], verb: name, query: command == :query
        )

        args
      end

      def parse_body!
        raw = request.raw_post
        return {} if raw.to_s.empty?

        parsed = JSON.parse(raw, symbolize_names: true)
        raise Errors::BadRequest, 'request body must be a JSON object' unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Errors.malformed_json(hint: BODY_HINT)
      end

      # A {Result}. `command` is the policy verb ({Executor::VERBS}); `name` the published name;
      # `handler` answers in place of the registered one.
      def call_wire(command:, args:, identity:, name:, handler: nil)
        # Refused with the arguments, before the toll.
        timezone = CallerTimezone.from_env(request.env)
        toll!(identity: identity, command: command, name: name, body: args)

        CurrentRequest.with(identity: identity, timezone: timezone) do
          Executor.new(connection: connection_for(identity), identity: identity)
                  .call(kind: command, args: args, name: name, handler: handler)
        end
      end

      def toll!(identity:, command:, name:, body:)
        pow = PowGate.proofs_from_header(request.get_header('HTTP_KIOSK_POW'))

        # A malformed proof is a 400, not a silent fresh 402.
        RequestValidation.validate_proofs!(pow) if Kiosk.configuration.validate_requests && pow

        PowGate.gate(
          identity: identity, command: command, method: request.request_method,
          verb: name, body: body, pow: pow
        )
      end

      # A lease: the GUCs and `pay`'s three transactions need one connection per request.
      def connection_for(_identity)
        ::ActiveRecord::Base.lease_connection
      end
    end
  end
end
