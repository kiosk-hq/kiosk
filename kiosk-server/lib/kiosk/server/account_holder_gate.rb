# frozen_string_literal: true

module Kiosk
  module Server
    # Requires a human signed in through the operator's own session
    # (`user_idp`), never an agent token. A browser is sent to `sign_in_path`;
    # any other caller gets a 401 naming where to sign in.
    module AccountHolderGate
      private

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

      def html_request?
        return true if request.format.html?

        request.headers["Accept"].to_s.include?("text/html")
      rescue StandardError
        false
      end

      # A host without the flash middleware must still redirect.
      def set_sign_in_flash(message)
        flash[:alert] = message
      rescue StandardError
        nil
      end

      # Devise's return-to key.
      def store_return_location
        session["user_return_to"] = request.fullpath
      rescue StandardError
        nil
      end
    end
  end
end
