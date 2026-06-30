# frozen_string_literal: true

module Kiosk
  module RLS
    # Adds RLS-specific fields to {Kiosk::Configuration} via include.
    # Provides lazy defaults so existing Configuration instances pick up the
    # new accessors without re-initialisation.
    #
    # See design spec §7.6 / §7.7 — the runtime role (default `app_role`)
    # has `NOBYPASSRLS`; the privileged role (default `system_role`) owns
    # the tables and is what `escalate_to :system` switches the connection
    # pool to. Kiosk does NOT create these roles — the provider's DBA does;
    # Kiosk only references them by name in `GRANT ... TO <role>` statements
    # and at boot-time verification (`kiosk doctor`).
    #
    # The `schema` name (default `kiosk`) is where Kiosk's helper functions
    # (`kiosk.current_user_id()` etc.) and tables (`kiosk.events`,
    # `kiosk.actions`, …) live. Overridable for providers whose primary
    # backend already uses a `kiosk` schema for its own purposes.
    module ConfigurationExtension
      def app_role
        @app_role ||= "app_role"
      end
      attr_writer :app_role

      def system_role
        @system_role ||= "system_role"
      end
      attr_writer :system_role

      def schema
        @schema ||= "kiosk"
      end
      attr_writer :schema

      # When set to true, SessionContext appends `SET LOCAL ROLE <app_role>`
      # inside EVERY request transaction (query / run / pay verbs). This means
      # app_role must have complete GRANTs on every table those verbs touch,
      # including the kiosk.* mandate tables (kiosk.agents, kiosk.payment_mandates,
      # kiosk.settlements, kiosk.cart_mandates, kiosk.intent_mandates, etc.) and all application
      # tables accessed by registered queries and actions.
      #
      # IMPORTANT — scope of the foodelivery demo:rls reference:
      # The foodelivery `demo:rls` task grants only `SELECT, INSERT, UPDATE, DELETE`
      # on the `orders` table, because its proof (rls_proof.rb) exercises a raw
      # unscoped `SELECT * FROM orders` path exclusively — no pay/run verbs run
      # under the enforced role. Setting `c.enforce_db_role = true` in that demo
      # is therefore a *proof-of-concept switch only*, not a full production
      # backstop. In a production deployment, app_role would need GRANTs on all
      # kiosk schema tables before enforce_db_role can be safely enabled.
      def enforce_db_role
        @enforce_db_role ||= false
      end
      attr_writer :enforce_db_role
    end
  end
end

Kiosk::Configuration.include(Kiosk::RLS::ConfigurationExtension)
