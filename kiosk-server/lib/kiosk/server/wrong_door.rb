# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  module Server
    # The account holder's browser pages. A JSON caller without a CSRF token is
    # an assistant at the wrong door: the answer points it at the protocol. Browser
    # requests re-raise untouched. Each page's controller sets WRONG_DOOR_MESSAGE.
    module WrongDoor
      extend ActiveSupport::Concern

      included do
        rescue_from ::ActionController::InvalidAuthenticityToken do |error|
          raise error unless json_request?

          render json: wrong_door_envelope, status: :unprocessable_entity
        end
      end

      private

      # An explicit JSON Accept or a JSON body; anything ambiguous counts as a browser.
      def json_request?
        return true if request.format.json?

        !!request.content_mime_type&.json?
      rescue StandardError
        false
      end

      # Not a protocol problem document or Kiosk error code: this page is not the protocol.
      def wrong_door_envelope
        hint = "assistants use the Kiosk HTTP API: GET #{request.base_url}/.well-known/kiosk.json " \
               'for the register/login endpoints, then GET <endpoint>/schema ' \
               '(public) for the verbs this origin serves'
        { ok: false,
          error: { code: 'invalid_authenticity_token', message: self.class::WRONG_DOOR_MESSAGE, hint: hint } }
      end
    end
  end
end
