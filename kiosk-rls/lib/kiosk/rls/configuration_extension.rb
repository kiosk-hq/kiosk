# frozen_string_literal: true

module Kiosk
  module RLS
    # Adds the RLS-only field to {Kiosk::Configuration} via include.
    #
    # The privileged role (default
    # `system_role`) owns the tables and is what `escalate_to :system`
    # switches the connection pool to. Kiosk does NOT create the role —
    # the provider's DBA does.
    #
    # `schema` and `app_role` live in kiosk-core's {Kiosk::Configuration}
    # (they are deployment vocabulary shared with kiosk-server, not
    # RLS-specific); `enforce_db_role` lives in kiosk-server's extension
    # next to its consumer, SessionContext.
    module ConfigurationExtension
      def system_role
        @system_role ||= "system_role"
      end
      attr_writer :system_role
    end
  end
end

Kiosk::Configuration.include(Kiosk::RLS::ConfigurationExtension)
