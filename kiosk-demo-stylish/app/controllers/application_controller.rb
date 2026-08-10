# Full ActionController::Base (not ::API): Devise's session controllers
# inherit from here, and the human-facing pages need cookies/flash/CSRF.
# The Kiosk wire controllers ship their own bases inside kiosk-server.
class ApplicationController < ActionController::Base
  # AGENT-SIGNPOST (K-459). Assistants guess web-app paths. A JSON POST at the
  # human sign-in form (`/users/sign_in`) carries no CSRF token, so Rails raises
  # ActionController::InvalidAuthenticityToken — and in PRODUCTION that never
  # reaches a controller: ShowExceptions falls through to PublicExceptions,
  # which serves the static public/422.html (shipped by K-532; before it, the
  # answer was 422 + `text/html` + `Content-Length: 0` — literally nothing to
  # act on). Prose written for a human is still not a result an assistant can
  # branch on, so hand a JSON-shaped caller the Kiosk error envelope with a
  # pointer to the wire instead. Browser requests re-raise untouched, so a
  # genuine CSRF failure on a genuine form still fails exactly as before
  # (deploy/production-smoke.sh relies on that for K-439 and pins this JSON
  # branch for K-534).
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
