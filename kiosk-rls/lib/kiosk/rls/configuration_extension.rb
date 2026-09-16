# frozen_string_literal: true

module Kiosk
  module RLS
    # Adds the RLS-only field to {Kiosk::Configuration} via include.
    #
    # `system_role` names the privileged role (default `"system_role"`) the
    # provider's DBA grants ownership/BYPASSRLS to. It is deployment
    # vocabulary only: nothing in this gem or kiosk-server READS it at
    # runtime — every tracked occurrence outside this definition and its specs
    # is a write (the demos' env files and initializers, the e2e fixtures, the
    # install template). Kiosk does NOT create the role; the DBA does.
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
