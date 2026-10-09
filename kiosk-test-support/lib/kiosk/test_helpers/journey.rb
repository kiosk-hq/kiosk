# frozen_string_literal: true

require "securerandom"

module Kiosk
  module TestHelpers
    # The journey-test DSL, for RSpec `type: :kiosk_journey` groups and Minitest
    # cases. The `as_*` scopes take a block and delegate to the executor.
    module Journey
      # @param user [#id, #role] the principal; `user.id` becomes `current_user_id`
      # @param role [String, Symbol, nil] defaults to `user.role`, else the first configured role
      def as_agent_of(user, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id:  user_id_of(user),
          role:     resolve_role(user, role),
          actor:    "agent",
          agent_id: SecureRandom.uuid,
        )
        scope_to(identity, &block)
      end

      def as_user(user, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id: user_id_of(user),
          role:    resolve_role(user, role),
          actor:   "human",
        )
        scope_to(identity, &block)
      end

      # An agent for a synthetic user named `name`, when no `users` row exists.
      def as_agent(name, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id:  "synthetic:#{name}",
          role:     role&.to_s || default_role,
          actor:    "agent",
          agent_id: SecureRandom.uuid,
        )
        scope_to(identity, &block)
      end

      def as_anonymous(&block)
        scope_to(nil, &block)
      end

      # Raw SQL; a query verb is {#run_query}.
      def query(sql)
        TestHelpers.require_executor!.query(sql)
      end

      def run_query(name, **args)
        TestHelpers.require_executor!.run_query(name, args)
      end

      def run_action(name, **args)
        TestHelpers.require_executor!.run_action(name, args)
      end

      # `Kiosk::Server::TestExecutor` raises `NotImplementedError` here.
      def pay_action(name, **args)
        TestHelpers.require_executor!.pay_action(name, args)
      end

      # Runs as `system_role`, so it can seed RLS tables; `owner:` sets `user_id`.
      def kiosk_seed(table, count: 1, owner: nil, **attrs)
        attrs = attrs.merge(user_id: user_id_of(owner)) if owner
        TestHelpers.require_executor!.seed(table, attrs, count: count)
      end

      private

      def scope_to(identity, &block)
        raise ArgumentError, "block required" unless block

        TestHelpers.require_executor!.with_identity(identity, &block)
      end

      def user_id_of(user)
        user.respond_to?(:id) ? user.id : user
      end

      def resolve_role(user, explicit)
        return explicit.to_s if explicit

        if user.respond_to?(:role) && user.role
          user.role.to_s
        else
          default_role
        end
      end

      def default_role
        roles = Kiosk.configuration.roles
        roles.first.to_s if roles && !roles.empty?
      end
    end
  end
end
