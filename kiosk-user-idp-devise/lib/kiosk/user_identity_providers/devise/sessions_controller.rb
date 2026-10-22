# frozen_string_literal: true

require 'kiosk/user_identity_providers/devise/wire_signpost'

module Kiosk
  module UserIdentityProviders
    class Devise
      # Devise's sign-in and sign-out, answering a JSON sign-out with no session
      # to end with a pointer to the protocol. Route it with
      # `devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }`.
      class SessionsController < ::Devise::SessionsController
        include WireSignpost

        private

        def respond_to_on_destroy(non_navigational_status: :no_content)
          return super unless non_navigational_status == :unauthorized && kiosk_json_request?

          render_wire_signpost :unauthorized, 'not_signed_in',
                               message: 'there is no human web session to end — /users/sign_out closes a ' \
                                        'browser session on this site, not a Kiosk credential',
                               hint: 'the credential of an assistant is its key at the Kiosk HTTP API. GET ' \
                                     "#{request.base_url}/.well-known/kiosk.json: auth.registration_url " \
                                     'registers your key, auth.token_url gives an access token, and ' \
                                     'auth.rotate_url replaces your key.'
        end
      end
    end
  end
end
