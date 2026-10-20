# frozen_string_literal: true

# Needs kiosk-server, which only a Rails host carries; this gem does not depend
# on it, so a test helper requires this file explicitly:
#   require "kiosk/test_helpers/conformance/in_process_origin"
#   require "kiosk/test_helpers/conformance/rspec"     # or .../minitest
#   Kiosk::TestHelpers::Conformance.origin = Kiosk::TestHelpers::Conformance::InProcessOrigin.new
require 'securerandom'

require 'kiosk/server'
require 'kiosk/test_helpers/conformance'
require 'kiosk/test_helpers/in_process_wire'

module Kiosk
  module TestHelpers
    module Conformance
      # The origin the conformance checks run against: the booted app's own
      # registries, routes and validators. A call goes through the verb's route
      # as an assistant's does, with a token the origin signs for the principal.
      # Calls do not roll back; undoing writes is the test framework's job.
      class InProcessOrigin
        # @param app [#call] the Rack app a call goes through; defaults to `Rails.application`
        # @param routes [ActionDispatch::Routing::RouteSet] defaults to `Rails.application.routes`
        def initialize(app: nil, routes: nil)
          @wire   = InProcessWire.new(app: app)
          @routes = routes
        end

        def mount_path = Kiosk.configuration.mount_path

        # Not memoised: development rebuilds the registry at `to_prepare`.
        def verbs
          descriptors(Kiosk::Server::Queries, :query) + descriptors(Kiosk::Server::Actions, :action)
        end

        # The action a request reaches, as `{controller:, action:, kiosk_verb:}`; nil when no route answers.
        def recognize(path, method:)
          verb_route(path, method.to_s.upcase) ||
            route_set.recognize_path(path, method: method.to_s.downcase.to_sym).slice(:controller, :action, :kiosk_verb)
        rescue ActionController::RoutingError
          nil
        end

        def call(name, kind:, params:, as: nil)
          @wire.call(name, kind: kind, params: params, identity: identity_for(as))
        end

        # Uses the wire's own validators, so a query's reserved `limit`/`cursor` pass as they do on the wire.
        def schema_errors(payload, schema:, verb:, kind:, slot:)
          if slot.to_s == 'input_schema'
            Kiosk::Server::RequestValidation.validate_arguments!(payload, input_schema: schema, verb: verb,
                                                                          query: kind == :query)
          else
            Kiosk::Server::ResponseValidation.validate_payload!(payload, output_schema: schema, verb: verb,
                                                                         kind: kind)
          end
          []
        rescue Kiosk::Server::Errors::Base => e
          ["#{slot}: #{e.message}"]
        end

        # A record contributes its `#id`; anything else is the principal id itself.
        def identity_for(subject, role: nil)
          raise ArgumentError, NO_PRINCIPAL if subject.nil?

          Kiosk::Identity.new(
            user_id: subject.respond_to?(:id) ? subject.id : subject,
            role: resolve_role(subject, role), actor: 'agent', agent_id: SecureRandom.uuid
          )
        end

        NO_PRINCIPAL =
          'a conformance call needs a principal — pass `as:` a record or a principal id. ' \
          'Every verb is served behind authentication, so there is no anonymous call ' \
          'to make.'
        private_constant :NO_PRINCIPAL

        private

        def descriptors(registry, kind)
          registry.catalog.map do |descriptor|
            Verb.new(
              name: descriptor[:name], kind: kind, reach: descriptor[:reach],
              input_schema: descriptor[:input_schema], output_schema: descriptor[:output_schema],
              example_params: descriptor[:example_params], endpoint: endpoint(registry.fetch(descriptor[:name]))
            )
          end
        end

        # The action that answers the verb: its own, or the engine's verb endpoint.
        def endpoint(handler)
          controller = handler.controller if handler.is_a?(Kiosk::Server::ControllerVerb)
          "#{controller.controller_path}##{handler.method_name}" if controller
        end

        # The verb route `kiosk do` drew at `path`, as the action it reaches.
        def verb_route(path, method)
          route = route_set.routes.find { |r| verb_route?(r) && r.verb == method && r.path.match(path) }
          return unless route

          controller, action = route.app.app.endpoint.split('#')
          { controller: controller, action: action, kiosk_verb: route.app.app.name }
        end

        def verb_route?(route)
          route.app.respond_to?(:app) && route.app.app.is_a?(Kiosk::Server::Routing::VerbRoute)
        end

        def route_set = @routes || ::Rails.application.routes

        def resolve_role(subject, explicit)
          return explicit.to_s if explicit
          return subject.role.to_s if subject.respond_to?(:role) && subject.role

          roles = Kiosk.configuration.roles
          roles.first.to_s if roles && !roles.empty?
        end
      end
    end
  end
end
