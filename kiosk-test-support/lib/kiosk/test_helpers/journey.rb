# frozen_string_literal: true

require "securerandom"

module Kiosk
  module TestHelpers
    # The journey-test DSL. Mixed into RSpec example
    # groups tagged `type: :kiosk_journey` (via `kiosk-rls-rspec`) and into
    # Minitest test cases via `include Kiosk::TestHelpers` (via
    # `kiosk-rls-minitest`).
    #
    # All identity-scoping helpers (`as_agent_of`, `as_user`, `as_agent`,
    # `as_anonymous`) require a block; they delegate to the executor's
    # `#with_identity` so the SQL/Action calls in the block run with the
    # right GUCs and roll back at the end.
    #
    # Calls outside any scope (`query("…")` at the top of the example)
    # raise (default deny). Use `as_anonymous` to assert
    # that explicitly.
    module Journey
      # Scope to an agent identity acting on behalf of `user`. Generates a
      # synthetic `agent_id` for this scope.
      #
      # @param user [#id, #role] the principal record; `user.id` becomes
      #   `current_user_id`. Tests typically pass an ActiveRecord row, but
      #   any object exposing `#id` works.
      # @param role [String, Symbol, nil] explicit role; falls back to
      #   `user.role` if the user responds, else the first configured role.
      def as_agent_of(user, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id:  user_id_of(user),
          role:     resolve_role(user, role),
          actor:    "agent",
          agent_id: SecureRandom.uuid,
        )
        scope_to(identity, &block)
      end

      # Scope to a human identity (web/mobile channel). No agent_id.
      def as_user(user, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id: user_id_of(user),
          role:    resolve_role(user, role),
          actor:   "human",
        )
        scope_to(identity, &block)
      end

      # Scope to a synthetic-user agent labelled `name`. For greenfield-style
      # tests where there is no real `users` row to anchor to.
      # The synthetic user_id is deterministic from `name` so repeated calls
      # in the same test refer to the same principal.
      def as_agent(name, role: nil, &block)
        identity = Kiosk::Identity.new(
          user_id:  "synthetic:#{name}",
          role:     role&.to_s || default_role,
          actor:    "agent",
          agent_id: SecureRandom.uuid,
        )
        scope_to(identity, &block)
      end

      # Scope to no identity (no GUCs set). Used to verify that RLS denies
      # by default. Passes `nil` to the executor's `with_identity`.
      def as_anonymous(&block)
        scope_to(nil, &block)
      end

      # Execute a SQL string under the current identity. Returns rows
      # (executor-dependent shape; typically an Array of Hashes).
      def query(sql)
        TestHelpers.require_executor!.query(sql)
      end

      # Invoke an Action by name with keyword args. Returns whatever the
      # Action returns (typically a result Hash or `Kiosk::Mandate`).
      def run_action(name, **args)
        TestHelpers.require_executor!.run_action(name, args)
      end

      # Invoke a pay-Action by name. Same contract as `run_action`, but the
      # real executor records an AP2 mandate trio.
      def pay_action(name, **args)
        TestHelpers.require_executor!.pay_action(name, args)
      end

      # Factory-style seeder. Runs as `system_role`, so it can populate
      # tables that have RLS enabled. `owner:` is sugar for a `user_id`
      # foreign key.
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
