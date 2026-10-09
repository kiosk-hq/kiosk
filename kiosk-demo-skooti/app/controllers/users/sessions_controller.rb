# frozen_string_literal: true

module Users
  # An assistant that signs out of a human page it never signed in to gets a
  # pointer to the wire instead of an empty 401.
  class SessionsController < Devise::SessionsController
    private

    def respond_to_on_destroy(non_navigational_status: :no_content)
      return super unless non_navigational_status == :unauthorized && kiosk_json_request?

      render status: :unauthorized, json: {
        ok:    false,
        error: {
          code:    "not_signed_in",
          message: "there is no human web session to end — /users/sign_out closes a " \
                   "browser session on this site, not a Kiosk credential",
          hint:    "assistant credentials live on the wire and are dropped there: GET " \
                   "#{request.base_url}/.well-known/kiosk.json for the register/login " \
                   "and revoke endpoints",
        },
      }
    end
  end
end
