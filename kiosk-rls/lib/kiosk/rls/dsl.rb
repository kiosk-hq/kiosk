# frozen_string_literal: true

require "kiosk/rls/policy"
require "kiosk/rls/table"
require "kiosk/rls/emitter"

module Kiosk
  module RLS
    # DSL methods callable from any host that provides `#execute(sql_string)`.
    # In the canonical Rails case the host is `ActiveRecord::Migration`
    # (see `kiosk/rls/migration` for the optional auto-injection).
    #
    # The four migration verbs from spec §7.3 (evolving policies):
    #
    #   enable_rls_on(table)                  — full-table RLS turn-on
    #   add_kiosk_policy_to(table, action)    — single-policy addition
    #   change_kiosk_policy_on(table, action) — replace-in-place
    #   remove_kiosk_policy_from(table, ...)  — single-policy removal
    #   rename_kiosk_policy_on(table, from:, to:)
    module DSL
      # Wrap a table in RLS: turn it on, GRANT the runtime role, declare
      # policies, attach a mandatory comment.
      #
      # @example
      #   enable_rls_on :rentals do
      #     policy :select, using: "user_id = kiosk.current_user_id()"
      #     policy :insert, check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
      #     comment "Scooter rentals owned by the renting user."
      #   end
      def enable_rls_on(table_name, app_role: nil, sequences: [], &block)
        table = Table.new(table_name, app_role: app_role, sequences: sequences)
        table.instance_eval(&block) if block
        table.validate!
        emit_rls(Emitter.statements_for(table))
      end

      # Add a single policy to an already-enabled table. Default name
      # `<table>_<action>` matches the convention `enable_rls_on` uses.
      def add_kiosk_policy_to(table_name, action, name: nil, using: nil, check: nil)
        policy = Policy.new(
          name:   name || default_policy_name(table_name, action),
          action: action,
          using:  using,
          check:  check,
        )
        emit_rls([Emitter.create_policy_sql(table_name.to_s, policy)])
      end

      # Replace a policy in place. PG has no `CREATE OR REPLACE POLICY`, so
      # this issues DROP + CREATE.
      def change_kiosk_policy_on(table_name, action, name: nil, using: nil, check: nil)
        policy_name = name || default_policy_name(table_name, action)
        emit_rls([
          Emitter.drop_policy_sql(table_name.to_s, policy_name),
          Emitter.create_policy_sql(
            table_name.to_s,
            Policy.new(name: policy_name, action: action, using: using, check: check),
          ),
        ])
      end

      # Remove a single policy. If a custom name was used at creation, pass
      # it as `name:`; otherwise the default `<table>_<action>` is assumed.
      def remove_kiosk_policy_from(table_name, action, name: nil)
        policy_name = name || default_policy_name(table_name, action)
        emit_rls([Emitter.drop_policy_sql(table_name.to_s, policy_name)])
      end

      # Rename a policy without redefining it. `from:` defaults to the
      # convention name `<table>_<from>`; `to:` is the new name verbatim.
      def rename_kiosk_policy_on(table_name, from:, to:)
        from_name = from.is_a?(Symbol) ? default_policy_name(table_name, from) : from.to_s
        to_name   = to.to_s
        emit_rls([Emitter.rename_policy_sql(table_name.to_s, from_name, to_name)])
      end

      private

      def default_policy_name(table_name, action)
        "#{table_name}_#{action}"
      end

      # How to ship SQL to PostgreSQL. By default delegates to `self.execute`
      # (which `ActiveRecord::Migration` provides). Override in tests or
      # alternative hosts (e.g. a Sequel migration) by aliasing `emit_rls`
      # to your own runner.
      def emit_rls(statements)
        statements.each { |sql| execute(sql) }
      end
    end
  end
end
