# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # The verbs the engine itself answers, `POST <endpoint>/payment_setup` and
    # `POST <endpoint>/request_kyc`, and every verb route that no controller
    # action can answer: 404 for an unknown name, 405 for a name of the other
    # kind. An operator's own verb goes straight to the action that declares
    # it ({Routing::VerbRoute}).
    #
    # Gates, in order: identity (401), the verb (404/405), the arguments
    # (400), the toll (402).
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
        raise wrong_method(command, name) if other.known.include?(name)

        # Neither: the registry's own 404 names what is registered.
        registry.describe(name)
      end

      def wrong_method(command, name)
        wanted = command == :query ? 'POST' : 'GET'
        Errors::MethodNotAllowed.new(
          command == :query ? "#{name.inspect} is an action, not a query" : "#{name.inspect} is a query, not an action",
          allow: wanted,
          hint: "call #{wanted} #{Kiosk.configuration.mount_path}/#{name} instead — " \
                'queries are GET, actions are POST.'
        )
      end
    end
  end
end
