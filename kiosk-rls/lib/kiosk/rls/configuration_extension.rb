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

      def enforce_db_role
        @enforce_db_role ||= false
      end
      attr_writer :enforce_db_role
    end
  end
end

Kiosk::Configuration.include(Kiosk::RLS::ConfigurationExtension)
