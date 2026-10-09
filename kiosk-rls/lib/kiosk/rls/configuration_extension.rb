# frozen_string_literal: true

module Kiosk
  module RLS
    # `system_role`: the privileged role the DBA creates and grants ownership/BYPASSRLS to.
    module ConfigurationExtension
      def system_role
        @system_role ||= "system_role"
      end
      attr_writer :system_role
    end
  end
end

Kiosk::Configuration.include(Kiosk::RLS::ConfigurationExtension)
