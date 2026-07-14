# frozen_string_literal: true

module Kiosk
  module RLS
    # Adds the RLS-only field to {Kiosk::Configuration} via include.
    #
    # `system_role` names the privileged role (default `"system_role"`) the
    # provider's DBA grants ownership/BYPASSRLS to. It is deployment
    # vocabulary only: nothing in this gem or kiosk-server reads it at
    # runtime yet — the seeding/escalation path that would consume it
    # (`escalate_to :system` in the full Action DSL) has not shipped, see
    # {Kiosk::Server::Actions}. Kiosk does NOT create the role; the DBA does.
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
