# frozen_string_literal: true

require 'active_support/concern'
require 'kiosk/user_identity_providers/devise'

module Kiosk
  module UserIdentityProviders
    class Devise
      # Answers a JSON caller at a human page with a pointer to the Kiosk HTTP API
      # instead of an empty error. Include it in ApplicationController.
      module WireSignpost
        extend ActiveSupport::Concern

        included do
          rescue_from ActionController::InvalidAuthenticityToken do |error|
            raise error unless kiosk_json_request?

            render_wire_signpost :unprocessable_entity, 'invalid_authenticity_token',
                                 message: 'this is the human sign-in page, not the Kiosk HTTP API — it needs a ' \
                                          'browser session and a CSRF token from its own form',
                                 hint: 'an assistant authenticates with its own key. GET ' \
                                       "#{request.base_url}/.well-known/kiosk.json: auth.registration_url " \
                                       'registers your key, auth.token_url gives an access token, and ' \
                                       'schema_url is the catalogue.'
          end
        end

        private

        def kiosk_json_request?
          request.format.json? || !!request.content_mime_type&.json?
        rescue StandardError
          false
        end

        def render_wire_signpost(status, code, message:, hint:)
          render status:, json: { ok: false, error: { code:, message:, hint: } }
        end
      end
    end
  end
end
