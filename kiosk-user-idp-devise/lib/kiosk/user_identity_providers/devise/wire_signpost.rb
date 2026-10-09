# frozen_string_literal: true

require "active_support/concern"
require "kiosk/user_identity_providers/devise"

module Kiosk
  module UserIdentityProviders
    class Devise
      # Answers a JSON caller at a human page with a pointer to the Kiosk wire
      # instead of an empty error. Include it in ApplicationController.
      module WireSignpost
        extend ActiveSupport::Concern

        included do
          rescue_from ActionController::InvalidAuthenticityToken do |error|
            raise error unless kiosk_json_request?

            render_wire_signpost :unprocessable_entity, "invalid_authenticity_token",
              message: "this is the human sign-in page, not the Kiosk wire — it needs a " \
                       "browser session and a CSRF token from its own form",
              hint:    "assistants authenticate with their own keypair: GET " \
                       "#{request.base_url}/.well-known/kiosk.json for the register/login " \
                       "endpoints, the catalog link and the modules this origin serves"
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
