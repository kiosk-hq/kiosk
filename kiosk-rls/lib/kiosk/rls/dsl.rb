# frozen_string_literal: true

require "kiosk/rls/policy"
require "kiosk/rls/table"
require "kiosk/rls/emitter"

module Kiosk
  module RLS
    # RLS migration verbs for any host that provides `#execute(sql)`;
    # Rails migrations get them through {Kiosk::RLS::Railtie}.
    module DSL
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

      def add_kiosk_policy_to(table_name, action, name: nil, using: nil, check: nil)
        policy = Policy.new(
          name:   name || default_policy_name(table_name, action),
          action: action,
          using:  using,
          check:  check,
        )
        emit_rls([Emitter.create_policy_sql(table_name.to_s, policy)])
      end

      # PG has no `CREATE OR REPLACE POLICY`.
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

      def remove_kiosk_policy_from(table_name, action, name: nil)
        policy_name = name || default_policy_name(table_name, action)
        emit_rls([Emitter.drop_policy_sql(table_name.to_s, policy_name)])
      end

      # A Symbol `from:` names the convention policy `<table>_<from>`.
      def rename_kiosk_policy_on(table_name, from:, to:)
        from_name = from.is_a?(Symbol) ? default_policy_name(table_name, from) : from.to_s
        to_name   = to.to_s
        emit_rls([Emitter.rename_policy_sql(table_name.to_s, from_name, to_name)])
      end

      private

      def default_policy_name(table_name, action)
        "#{table_name}_#{action}"
      end

      def emit_rls(statements)
        statements.each { |sql| execute(sql) }
      end
    end
  end
end
