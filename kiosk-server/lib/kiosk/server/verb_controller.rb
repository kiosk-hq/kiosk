# frozen_string_literal: true

require "action_controller"
require "kiosk/server/actions"
require "kiosk/server/argument_decoder"
require "kiosk/server/errors"
require "kiosk/server/kyc"
require "kiosk/server/payment_setup"
require "kiosk/server/queries"
require "kiosk/server/request_validation"
require "kiosk/server/wire_controller"

module Kiosk
  module Server
    # The per-verb wire, one endpoint per registered verb under the mount:
    #
    #   GET  <endpoint>/<query-name>?<args>    a query  — safe, no body
    #   POST <endpoint>/<action-name>          an action — JSON body
    #
    # Gates, in order: identity (401), the verb (404/405), the arguments
    # (400), the toll (402). Answers and refusals are written by {WireController}.
    class VerbController < WireController
      # GET <endpoint>/<query-name>
      def show
        serve(:query)
      end

      # POST <endpoint>/<action-name>
      def create
        serve(:run)
      end

      private

      def serve(command)
        name       = params[:kiosk_verb].to_s
        identity   = resolve_identity!
        PaymentSetup.served! if name == PaymentSetup::NAME
        Kyc.served! if name == Kyc::NAME
        descriptor = descriptor_for!(command, name)
        args       = arguments_for(command, name, descriptor)

        execute_wire(command: command, args: args, identity: identity, name: name)
      end

      # 404 verb_not_found for an unknown name; 405 with `Allow:` for a known
      # name called with the other kind's method.
      def descriptor_for!(command, name)
        registry, other = command == :query ? [Queries, Actions] : [Actions, Queries]
        return registry.describe(name) if registry.known.include?(name)

        if other.known.include?(name)
          wanted = command == :query ? "POST" : "GET"
          raise Errors::MethodNotAllowed.new(
            command == :query ? "#{name.inspect} is an action, not a query"
                              : "#{name.inspect} is a query, not an action",
            allow: wanted,
            hint:  "call #{wanted} #{Kiosk.configuration.mount_path}/#{name} instead — " \
                   "queries are GET, actions are POST.",
          )
        end

        # Not registered as either: let the registry raise its own
        # VerbNotFound, whose hint names what IS registered for this kind.
        registry.describe(name)
      end

      # A query's arguments come off the query string and have to have their
      # declared types recovered ({ArgumentDecoder}); an action's arrive as
      # JSON and already carry them. There is no third channel: a query string
      # on a POST is not read, and a body on a GET is not read.
      def arguments_for(command, name, descriptor)
        args = if command == :query
                 ArgumentDecoder.decode(request.query_string, input_schema: descriptor[:input_schema])
               else
                 parse_body!
               end

        # UNCONDITIONAL, deliberately. `input_schema` is REQUIRED on every
        # verb and §8.1 item 5 makes the operator coerce-then-validate before
        # the handler sees an argument, so a per-verb endpoint that validated
        # only when a flag was set would be non-conformant with the flag off —
        # and the typed 400 for an invalid filter value would fall out of the
        # schema layer on some origins and not others. `validate_requests`
        # covers something else: the opt-in SHAPE checks on a `Kiosk-PoW`
        # header and on the RESERVED plane's own request bodies, both of
        # which §16.3 anchor 1 makes a SHOULD rather than a MUST.
        #
        # Which is why `json_schemer` is a runtime dependency of this gem (see
        # the gemspec): an origin that cannot load a validator
        # cannot serve a conformant wire. It is still required lazily, and a
        # vendored checkout without it still gets {Errors::ConfigurationError}
        # naming the gem rather than a LoadError at boot.
        RequestValidation.validate_arguments!(
          args, input_schema: descriptor[:input_schema], verb: name
        )

        args
      end

    end
  end
end
