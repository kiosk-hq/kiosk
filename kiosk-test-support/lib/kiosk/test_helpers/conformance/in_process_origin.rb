# frozen_string_literal: true

# Needs kiosk-server, which only a Rails host carries; this gem does not depend
# on it, so a test helper requires this file explicitly:
#   require "kiosk/test_helpers/conformance/in_process_origin"
#   require "kiosk/test_helpers/conformance/rspec"     # or .../minitest
#   Kiosk::TestHelpers::Conformance.origin = Kiosk::TestHelpers::Conformance::InProcessOrigin.new
require 'securerandom'

require 'kiosk/server'
require 'kiosk/test_helpers/conformance'

module Kiosk
  module TestHelpers
    module Conformance
      # The origin the conformance checks run against: the booted engine's own
      # registries, router and validators, minus HTTP and authentication. Calls
      # do not roll back; undoing writes is the test framework's job.
      class InProcessOrigin
        attr_reader :connection

        # @param connection [#exec_query, #transaction] defaults to `ActiveRecord::Base.lease_connection`
        # @param routes [#recognize_path] defaults to `Rails.application.routes`
        # @param actor [String] "agent", "human" or "service"
        def initialize(connection: nil, routes: nil, actor: 'agent')
          @connection = connection
          @routes     = routes
          @actor      = actor.to_s
        end

        def mount_path = Kiosk.configuration.mount_path

        # Not memoised: development rebuilds the registry at `to_prepare`.
        def verbs
          descriptors(Kiosk::Server::Queries, :query) + descriptors(Kiosk::Server::Actions, :action)
        end

        # nil when no route answers.
        def recognize(path, method:)
          recognized = route_set.recognize_path(path, method: method.to_s.downcase.to_sym)
          {
            controller: recognized[:controller],
            action: recognized[:action],
            kiosk_verb: recognized[:kiosk_verb]
          }
        rescue StandardError
          nil
        end

        # Arguments are validated first, as the per-verb wire does.
        def call(name, kind:, params:, as: nil)
          registry = kind == :query ? Kiosk::Server::Queries : Kiosk::Server::Actions
          handler  = registry.fetch(name)
          Kiosk::Server::RequestValidation.validate_arguments!(params, input_schema: registry.describe(name)[:input_schema], verb: name.to_s)
          unwrap(answer_as(identity_for(as)) { handler.call(symbolize(params)) })
        end

        # Uses the wire's own validators, so reserved `limit`/`cursor` pass as they do on the wire.
        def schema_errors(payload, schema:, verb:, kind:, slot:)
          if slot.to_s == 'input_schema'
            Kiosk::Server::RequestValidation.validate_arguments!(payload, input_schema: schema, verb: verb)
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
            role: resolve_role(subject, role),
            actor: @actor,
            agent_id: @actor == 'agent' ? SecureRandom.uuid : nil
          )
        end

        NO_PRINCIPAL =
          'a conformance call needs a principal — pass `as:` a record or a principal id. ' \
          'Every verb is served behind authentication, so there is no anonymous call ' \
          'to make.'
        private_constant :NO_PRINCIPAL

        private

        def answer_as(identity)
          answer = nil
          Kiosk::Server::SessionContext.open(connection: resolved_connection, identity: identity) do
            Kiosk::Server::CurrentRequest.with(identity: identity) { answer = yield }
          end
          answer
        end

        def descriptors(registry, kind)
          registry.catalog.map do |descriptor|
            Verb.new(
              name: descriptor[:name],
              kind: kind,
              reach: descriptor[:reach],
              input_schema: descriptor[:input_schema],
              output_schema: descriptor[:output_schema],
              example_params: descriptor[:example_params]
            )
          end
        end

        def route_set = @routes || ::Rails.application.routes

        # Not memoised: each call is independent of whichever connection was current at build time.
        def resolved_connection = @connection || ::ActiveRecord::Base.lease_connection

        def resolve_role(subject, explicit)
          return explicit.to_s if explicit
          return subject.role.to_s if subject.respond_to?(:role) && subject.role

          roles = Kiosk.configuration.roles
          roles.first.to_s if roles && !roles.empty?
        end

        # The wire's body for a paginated query is its rows; cursor and total travel as headers.
        def unwrap(answer) = answer.is_a?(Kiosk::Server::Page) ? answer.rows : answer

        def symbolize(params)
          return params unless params.is_a?(Hash)

          params.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
        end
      end
    end
  end
end
