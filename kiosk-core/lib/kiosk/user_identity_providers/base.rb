# frozen_string_literal: true

module Kiosk
  module UserIdentityProviders
    # Base for a user-IdP adapter (`kiosk-user-idp-*`): consumes whatever already
    # authenticates the principal at the provider.
    class Base
      # @return [Kiosk::Identity, nil]
      def verify(_request)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end

      # Unused extension point: nothing in kiosk-server calls it.
      def user_active?(_user_id)
        true
      end
    end
  end
end
