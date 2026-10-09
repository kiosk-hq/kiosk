# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # An assistant that posts JSON to a human page has no CSRF token; tell it
  # where the wire is instead of failing with an empty 422.
  rescue_from ActionController::InvalidAuthenticityToken do |error|
    raise error unless kiosk_json_request?

    render status: :unprocessable_entity, json: {
      ok:    false,
      error: {
        code:    "invalid_authenticity_token",
        message: "this is the human sign-in page, not the Kiosk wire — it needs a " \
                 "browser session and a CSRF token from its own form",
        hint:    "assistants authenticate with their own keypair: GET " \
                 "#{request.base_url}/.well-known/kiosk.json for the register/login " \
                 "endpoints, the catalog link and the modules this origin serves",
      },
    }
  end

  private

  def kiosk_json_request?
    request.format.json? || !!request.content_mime_type&.json?
  rescue StandardError
    false
  end
end
