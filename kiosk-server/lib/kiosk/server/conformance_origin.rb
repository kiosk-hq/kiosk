# frozen_string_literal: true

# Not auto-loaded by `require "kiosk/server"` — this file is test-time
# infrastructure and shouldn't appear in production boot. Wire it up
# explicitly in your spec / test helper, exactly as you would the
# TestExecutor beside it:
#
#   # spec/rails_helper.rb (RSpec) or test/test_helper.rb (Minitest)
#   require "kiosk/server/conformance_origin"
#   require "kiosk/test_helpers/conformance/rspec"     # or .../minitest
#
#   Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new
require "securerandom"

require "kiosk/server/actions"
require "kiosk/server/current_request"
require "kiosk/server/errors"
require "kiosk/server/queries"
require "kiosk/server/request_validation"
require "kiosk/server/response_validation"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/test_helpers/conformance"

module Kiosk
  module Server
    # The ORIGIN the conformance checks run against, backed by a real Kiosk
    # engine in a real Rails application.
    #
    # {Kiosk::TestHelpers::Conformance} asks four questions of an origin — what
    # verbs do you declare, what does your router say about this path, what does
    # this verb answer as this principal, and does this payload satisfy this
    # schema — and knows nothing about Rails. This class is the answer for an
    # app that has booted the engine, and it takes each answer from the SAME
    # source the running server takes it from:
    #
    #   * the verbs come from {Queries.catalog} and {Actions.catalog}, which is
    #     the registry {HandlerRegistrations} built from the operator's own
    #     handler controllers at `to_prepare`. Reading them means a verb
    #     declared by metaprogramming is visible, which a text parser cannot
    #     promise;
    #   * the routes come from `Rails.application.routes.recognize_path`, the
    #     table Rails actually dispatches on, not from a routes FILE;
    #   * a call goes through the registered handler inside a GUC-scoped
    #     {SessionContext} and a {CurrentRequest} identity, which is what the
    #     wire does — minus the HTTP hop, the authentication ceremony and the
    #     proof-of-work gate;
    #   * schema failures come from {ResponseValidation.validate_payload!}, so a
    #     conformance test and a running server with
    #     `Kiosk.configuration.validate_responses` on cannot disagree about
    #     whether an answer satisfies its own descriptor.
    #
    # ── The transaction, and who owns it ──────────────────────────────────
    #
    # {SessionContext#open} wraps each call in `connection.transaction` because
    # the GUCs it sets are transaction-local; it does NOT roll back. That is
    # deliberate here: an action under test WRITES, and undoing that write is
    # the test framework's job — Rails' transactional tests, an RSpec
    # `use_transactional_fixtures`, or the caller's own `around`. An origin that
    # rolled back on its own would silently defeat a test that meant to assert
    # what two calls do in sequence.
    #
    # ── What it does NOT do ───────────────────────────────────────────────
    #
    # It does not authenticate. `as:` names a principal directly, so no bearer
    # is minted, no proof-of-work is solved and no device grant is polled —
    # those are the wire's own beats and the demos' flow tasks drive them. It
    # does not emit audit events and it does not settle payments.
    class ConformanceOrigin
      attr_reader :connection

      # @param connection [#exec_query, #transaction] the app connection the
      #   GUC-scoped session runs on. Defaults to
      #   `ActiveRecord::Base.lease_connection`, resolved lazily so building an
      #   origin needs no database.
      # @param routes [#recognize_path] the route set to ask. Defaults to
      #   `Rails.application.routes`.
      # @param actor [String] the channel a call is made on: "agent" (the
      #   default, and what an assistant is), "human" or "service".
      def initialize(connection: nil, routes: nil, actor: "agent")
        @connection = connection
        @routes     = routes
        @actor      = actor.to_s
      end

      # The mount path the wire is served under, from the operator's own
      # configuration rather than from a literal.
      def mount_path = Kiosk.configuration.mount_path

      # Every declared verb, queries then actions, each as a
      # {Kiosk::TestHelpers::Conformance::Verb}.
      #
      # Built on every call, not memoised: in development the registry is
      # rebuilt at `to_prepare`, and an origin holding a stale list would
      # report on verbs the app no longer serves.
      def verbs
        descriptors(Queries, :query) + descriptors(Actions, :action)
      end

      # What the router says about this path and method, or nil when nothing
      # answers. `recognize_path` raises `ActionController::RoutingError` for a
      # path with no route — that is "nothing answers", not an error.
      def recognize(path, method:)
        recognized = route_set.recognize_path(path, method: method.to_s.downcase.to_sym)
        {
          controller: recognized[:controller],
          action:     recognized[:action],
          kiosk_verb: recognized[:kiosk_verb],
        }
      rescue StandardError
        nil
      end

      # Call one verb as one principal.
      #
      # Arguments are validated against the verb's own `input_schema` first,
      # with the engine's own validator, because that is what the per-verb wire
      # does unconditionally before a handler sees an argument — a conformance
      # call that skipped it would exercise a path no caller can reach.
      def call(name, kind:, params:, as: nil)
        registry = kind == :query ? Queries : Actions
        handler  = registry.fetch(name)
        RequestValidation.validate_arguments!(
          params, input_schema: registry.describe(name)[:input_schema], verb: name.to_s
        )

        identity = identity_for(as)
        answer   = nil
        SessionContext.open(connection: resolved_connection, identity: identity) do
          CurrentRequest.with(identity: identity) { answer = handler.call(symbolize(params)) }
        end
        unwrap(answer)
      end

      # Schema failures as a list of strings, from the engine's OWN validator.
      #
      # {ResponseValidation.validate_payload!} raises one error naming the verb
      # and the failing pointers; that message is what a running server with
      # `validate_responses` on puts in front of an operator, so it is what this
      # puts in front of them too.
      def schema_errors(payload, schema:, verb:, kind:, slot:)
        ResponseValidation.validate_payload!(payload, output_schema: schema, verb: verb, kind: kind)
        []
      rescue Errors::Base => e
        ["#{slot}: #{e.message}"]
      end

      # The identity a `as:` subject stands for. A record answering `#id` (the
      # ordinary case — an ActiveRecord row) contributes its id; anything else
      # is taken as the principal id itself, so `as: "synthetic:alice"` works
      # with no fixture at all. `nil` is the anonymous principal and is refused:
      # every verb runs behind authentication, so a call with no principal is a
      # test asking a question the wire cannot be asked.
      def identity_for(subject, role: nil)
        if subject.nil?
          raise ArgumentError,
                "a conformance call needs a principal — pass `as:` a record or a principal id. " \
                "Every verb is served behind authentication, so there is no anonymous call " \
                "to make."
        end

        Kiosk::Identity.new(
          user_id:  subject.respond_to?(:id) ? subject.id : subject,
          role:     resolve_role(subject, role),
          actor:    @actor,
          agent_id: @actor == "agent" ? SecureRandom.uuid : nil,
        )
      end

      private

      def descriptors(registry, kind)
        registry.catalog.map do |descriptor|
          Kiosk::TestHelpers::Conformance::Verb.new(
            name:           descriptor[:name],
            kind:           kind,
            reach:          descriptor[:reach],
            input_schema:   descriptor[:input_schema],
            output_schema:  descriptor[:output_schema],
            example_params: descriptor[:example_params],
          )
        end
      end

      def route_set = @routes || ::Rails.application.routes

      # `lease_connection`, not `connection`: the latter is soft-deprecated in
      # Rails 8.1 and RAISES under `permanent_connection_checkout = :disallowed`.
      #
      # Resolved on EVERY call rather than memoised, which is the opposite of
      # what {TestExecutor} does and for the opposite reason: that object holds
      # one connection across many `as_user` blocks that each open a
      # transaction on it, while each call here is independent and an origin
      # built once in a test helper would otherwise pin whichever connection
      # the first example happened to be on.
      def resolved_connection = @connection || ::ActiveRecord::Base.lease_connection

      def resolve_role(subject, explicit)
        return explicit.to_s if explicit
        return subject.role.to_s if subject.respond_to?(:role) && subject.role

        roles = Kiosk.configuration.roles
        roles.first.to_s if roles && !roles.empty?
      end

      # A paginated query answers a {Page}; the wire's body is its rows, with
      # the cursor and total travelling as headers. The checks compare what a
      # caller receives, so the rows are what comes back here.
      def unwrap(answer) = answer.is_a?(Page) ? answer.rows : answer

      def symbolize(params)
        return params unless params.is_a?(Hash)

        params.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      end
    end
  end
end
