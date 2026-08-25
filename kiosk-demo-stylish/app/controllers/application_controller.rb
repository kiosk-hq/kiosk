# frozen_string_literal: true

# Full ActionController::Base (not ::API): Devise's session controllers
# inherit from here, and the human-facing pages need cookies/flash/CSRF.
# The Kiosk wire controllers get the wire surface from the `Kiosk::Handler`
# MIXIN, not from a base class in kiosk-server; here Kiosk::AppointmentsController and
# Kiosk::FrontDeskController subclass THIS class (K-1017).
class ApplicationController < ActionController::Base
  # AGENT-SIGNPOST (K-459). Assistants guess web-app paths. A JSON POST at the
  # human sign-in form (`/users/sign_in`) carries no CSRF token, so Rails' forgery
  # check raises ActionController::InvalidAuthenticityToken — INSIDE the
  # controller, in a before_action, which is why the handler below is what sees
  # it first, in production as anywhere else. Prose written for a human is not a
  # result an assistant can branch on, so a JSON-shaped caller gets the Kiosk
  # error envelope with a pointer to the wire.
  #
  # Everything else is re-raised untouched, and only THEN leaves the controller:
  # in production ShowExceptions falls through to PublicExceptions, which serves
  # the static public/422.html (shipped by K-532; before it, the answer was 422 +
  # `text/html` + `Content-Length: 0` — literally nothing to act on). So a genuine
  # CSRF failure on a genuine form still fails exactly as before.
  # deploy/production-smoke.sh depends on both halves: K-439 on the browser half,
  # K-534 on this JSON branch — and that assertion can only pass because the
  # rescue runs, since public/422.html contains no `invalid_authenticity_token`.
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
                 "and schema/query/run/pay endpoints",
      },
    }
  end

  private

  # Narrow on purpose: an explicit JSON `Accept`, or a JSON request body.
  # Anything ambiguous (a form post, `*/*`, an unparseable Content-Type) counts
  # as a browser and keeps today's behaviour.
  def kiosk_json_request?
    request.format.json? || !!request.content_mime_type&.json?
  rescue StandardError
    false
  end
end
