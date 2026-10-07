# frozen_string_literal: true

module Kiosk
  module Server
    # The signed-in-human gate the two HTML pages of the account-binding
    # ceremony share: the verify page ({DeviceVerifyController}) and the
    # manage-assistants page ({AssistantsController}).
    #
    # Both authenticate the approving human through the provider's own session
    # (`Kiosk.configuration.user_idp`) and never through an agent Bearer token,
    # and neither ships a login screen — the engine is IdP-neutral and cannot
    # know the operator's sign-in URL. An operator that sets
    # `Kiosk.configuration.sign_in_path` sends a browser there and back; any
    # other caller gets the 401, whose body then names that sign-in URL and this
    # page's, so whoever fetched it can hand a working path to the human.
    module AccountHolderGate
      private

      # @param prompt [String] what the 401 body tells a caller to do
      # @param flash_alert [String] the notice the sign-in page shows a browser
      # @return [Boolean] true when `@identity` is set and the action may run
      def require_account_holder!(prompt:, flash_alert:)
        @identity = Kiosk.configuration.user_idp&.verify(request)
        return true if @identity

        sign_in_path = Kiosk.configuration.sign_in_path
        if sign_in_path && html_request?
          set_sign_in_flash(flash_alert)
          store_return_location
          redirect_to sign_in_path
          return false
        end

        render plain: sign_in_path ? "#{prompt} #{sign_in_directions(sign_in_path)}" : prompt,
               status: :unauthorized
        false
      end

      def sign_in_directions(sign_in_path)
        "Sign in at #{request.base_url}#{sign_in_path} — or open #{request.original_url} " \
          "in a browser, which goes there and comes back here."
      end

      # Browser vs API: prefer the negotiated format, but also accept a raw
      # `Accept: text/html` (a curl/bookmark hit whose format Rails could not
      # infer). API clients send JSON and get the plain 401 unchanged.
      def html_request?
        return true if request.format.html?

        request.headers["Accept"].to_s.include?("text/html")
      rescue StandardError
        false
      end

      # The flash mixin is present on ActionController::Base, but
      # `request.flash` needs the flash middleware in the stack — absent on a
      # bare Rack host or Metal dispatch — so a missing flash must not abort
      # the redirect.
      def set_sign_in_flash(message)
        flash[:alert] = message
      rescue StandardError
        nil
      end

      # Devise convention: remember where the visitor was headed so login can
      # bounce them back. Harmless if unused by the IdP.
      def store_return_location
        session["user_return_to"] = request.fullpath
      rescue StandardError
        nil
      end
    end
  end
end
