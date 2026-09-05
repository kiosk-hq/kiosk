# frozen_string_literal: true

# Full ActionController::Base (not ::API): Devise's session controllers
# inherit from here, and the human-facing pages need cookies/flash/CSRF.
# The Kiosk wire controllers get the wire surface from the `Kiosk::Handler`
# MIXIN, not from a base class in kiosk-server; here Kiosk::TodoListsController and
# Kiosk::HouseholdController subclass THIS class.
class ApplicationController < ActionController::Base
  # AGENT-SIGNPOST. Assistants guess web-app paths. A JSON POST at the
  # human sign-in form (`/users/sign_in`) carries no CSRF token, so Rails' forgery
  # check raises ActionController::InvalidAuthenticityToken — INSIDE the
  # controller, in a before_action, which is why the handler below is what sees
  # it first, in production as anywhere else. Prose written for a human is not a
  # result an assistant can branch on, so a JSON-shaped caller gets a JSON body
  # with a pointer to the wire.
  #
  # THAT BODY IS DELIBERATELY NOT THE WIRE'S SHAPE, and it is not «the Kiosk
  # error envelope» — a phrase that names the wire CONTRACT, and is false twice
  # over. The wire answers FLAT RFC 9457 problem documents served as
  # `application/problem+json`, whose top-level `code` is the branch point;
  # `{ok:false, error:{…}}` is the 0.3 shape, deleted along with the endpoints
  # that served it. What is rendered below is a COURTESY to a caller that dialed
  # the wrong door — a human sign-in page is not a wire verb — rather than a
  # contract anything parses, and its `error.code` is non-wire for the same
  # reason: this endpoint must not borrow a code from the spec's closed error
  # table. kiosk-server's own signposts render the same shape and record the
  # same choice (assistants_controller.rb, device_verify_controller.rb); a demo
  # is read AS the reference implementation, so it has to say so rather than
  # leave a reader to infer a contract from a courtesy.
  #
  # Everything else is re-raised untouched, and only THEN leaves the controller:
  # in production ShowExceptions falls through to PublicExceptions, which serves
  # the static public/422.html — there so the answer is not a bare 422 +
  # `text/html` + `Content-Length: 0`, literally nothing to act on. So a genuine
  # CSRF failure on a genuine form still fails exactly as before.
  # deploy/production-smoke.sh asserts both halves — one on the browser answer,
  # one on this JSON branch — and the JSON assertion can only pass because the
  # rescue runs, since public/422.html contains no `invalid_authenticity_token`.
  rescue_from ActionController::InvalidAuthenticityToken do |error|
    raise error unless kiosk_json_request?

    render status: :unprocessable_entity, json: {
      ok:    false,
      error: {
        code:    "invalid_authenticity_token",
        message: "this is the human sign-in page, not the Kiosk wire — it needs a " \
                 "browser session and a CSRF token from its own form",
        # NAME WHAT THE DOCUMENT CARRIES, NEVER A VERB LIST. A hint naming «the
        # register/login and schema/query/run/pay endpoints» would be false on
        # both readings: protocol 0.4 deleted `POST /kiosk/query` and `POST
        # /kiosk/run` outright (both answer the ordinary 404 an AUTHENTICATED
        # caller gets, and 401 without a bearer, since auth precedes verb
        # dispatch; this app's own redteam beat asserts both), and
        # `capabilities` publishes MODULE names (schema/queries/actions/pay). A
        # list here is a third copy of the catalog — kiosk.json deliberately
        # publishes no verb names — so it would rot the same way. The reader of
        # this body is a JSON-dialing assistant that has just hit the human
        # sign-in page: it cannot check the hint.
        hint:    "assistants authenticate with their own keypair: GET " \
                 "#{request.base_url}/.well-known/kiosk.json for the register/login " \
                 "endpoints, the catalog link and the modules this origin serves",
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
