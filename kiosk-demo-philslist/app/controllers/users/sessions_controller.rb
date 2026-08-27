# frozen_string_literal: true

module Users
  # AGENT-SIGNPOST (K-533) — the sign-OUT half of the K-459 sign-IN signpost.
  #
  # `DELETE /users/sign_out` from a caller that holds no web session is answered
  # by Devise with `head :unauthorized` (SessionsController#verify_signed_out_user
  # → respond_to_on_destroy(non_navigational_status: :unauthorized)). For a
  # JSON-shaped caller that is a 401 carrying `Content-Type: application/json`
  # and ZERO bytes — a content type promising JSON with nothing to parse, which
  # is less actionable than an honest HTML error. Hand that caller a JSON body
  # instead, with the same pointer to the wire the sign-in signpost gives.
  #
  # NOT «the Kiosk error envelope», which is what this comment used to call it
  # (K-1092): that phrase names the wire CONTRACT, and the wire's contract is a
  # FLAT RFC 9457 problem document served as `application/problem+json` — the
  # `{ok:false, error:{…}}` shape below is 0.3's, deleted with the endpoints
  # that served it (K-808, T-074 = A). `/users/sign_out` is a browser page, not
  # a wire verb, so this body is a COURTESY to a caller that dialed the wrong
  # door rather than a contract anything parses, and its `error.code` is
  # deliberately non-wire. kiosk-server's own wrong-door signposts render the
  # same shape and record the same choice.
  #
  # Everything else is Devise's behaviour untouched: browsers (navigational
  # formats) still get the redirect + flash, and a REAL sign-out still answers
  # `204 No Content`, where an empty body is the correct answer and says so.
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
