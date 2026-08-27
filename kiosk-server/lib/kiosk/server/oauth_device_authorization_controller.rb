# frozen_string_literal: true

# The engine draws the route.

require "action_controller"
require "kiosk/server/device_code_grant"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST <endpoint>/oauth/device_authorization — RFC 8628 §3.1, opening
    # the claim half of the account-binding ceremony (auth.md
    # "User Claimed"). The initiating agent's first call.
    #
    # Request: `application/x-www-form-urlencoded` (OAuth convention)
    #   client_id    required — identifier of the calling client
    #   public_key   required — PEM of the RSA-2048+ key the ceremony
    #                 will bind; the token poll must later prove
    #                 possession of it (BIND-POP)
    #
    # There is NO third parameter. `role` and `scope` are REFUSED with
    # `400 invalid_request` rather than ignored — see {#create}.
    #
    # Response 200 (RFC 8628 §3.2):
    #   {
    #     "device_code":               "<opaque, ~32B base64url>",
    #     "user_code":                 "WDJB-MJHT",
    #     "verification_uri":          "<provider>/<mount>/oauth/device/verify",
    #     "verification_uri_complete": "<verification_uri>?user_code=WDJB-MJHT",
    #     "expires_in":                900,
    #     "interval":                  5
    #   }
    class OauthDeviceAuthorizationController < ::ActionController::API
      def create
        client_id = params[:client_id].to_s
        if client_id.empty?
          return render_oauth_error(:invalid_request, "client_id parameter required", status: 400)
        end

        # The binding ceremony is key-bound: without a key there is
        # nothing to bind, and BIND-POP has nothing to verify. Reuses
        # PopVerifier's key checks (RSA-2048 floor) so the binding
        # surface can never accept a key registration would reject.
        public_key = params[:public_key].to_s
        if public_key.empty?
          return render_oauth_error(:invalid_request, "public_key parameter required", status: 400)
        end
        begin
          PopVerifier.load_public_key(public_key.strip)
        rescue Errors::BadRequest => e
          return render_oauth_error(:invalid_request, e.message, status: 400)
        end

        # THE AGENT NEVER SELF-SELECTS ITS ROLE (ADR-0011 amendment; K-072).
        #
        # This request is UNAUTHENTICATED — anyone holding a keypair can send
        # it — so anything it carries is an assertion by a stranger. Until
        # K-1109 the `role`/`scope` parameter was read from HERE, written onto
        # the row, and baked into the JWT the poll returns; the only filter was
        # membership of `config.roles`. On an origin declaring more than one
        # role that is a privilege-escalation primitive with no authenticated
        # step behind it: at `kiosk-demo-stylish` (`%i[customer owner]`) a
        # stranger's `role=owner` reached a token whose `role` claim was
        # `owner`, and the approving human — a plain customer — was never shown
        # the word. `config.roles` is a DECLARATION of the roles this origin
        # has, not a grant of them to whoever asks.
        #
        # The role is now sourced where ADR-0011 puts it: from the APPROVING
        # HUMAN's own identity, captured by {DeviceVerification.approve} off
        # `user_idp`'s `Identity#role` at the verify page — the same capture
        # {AuthController#link} already performed for the link direction, so
        # both halves of the binding ceremony read the role from the same
        # place and a ceremony can never mint a privilege its approver does
        # not hold.
        #
        # REFUSED, NOT IGNORED. A silently dropped parameter leaves the caller
        # believing it got what it asked for, and leaves the next reader of
        # this file unable to tell a deliberate drop from a bug — the same
        # reasoning protocol.md §7.1(2) applies to a verb that names its own
        # principal ("the conforming answer is 400 naming that parameter, not
        # a silently ignored argument"). An EMPTY value is tolerated: it
        # asserts nothing.
        if (offending = %i[role scope].find { |name| !params[name].to_s.empty? })
          return render_oauth_error(
            :invalid_request,
            "#{offending} is not accepted here — an assistant does not choose its own role. " \
            "The role of a bound assistant is the approving account holder's own role, " \
            "read from this provider's identity system when they approve at the verify page.",
            status: 400,
          )
        end

        result = DeviceCodeGrant.start(
          client_id:      client_id,
          public_key_pem: public_key,
        )

        Kiosk::Server::Headers.add_to(response.headers)
        render json: {
          device_code:               result[:device_code],
          user_code:                 result[:user_code],
          verification_uri:          verification_uri,
          verification_uri_complete: "#{verification_uri}?user_code=#{result[:user_code]}",
          expires_in:                result[:expires_in],
          interval:                  result[:interval],
        }
      end

      private

      # `<request.base_url>` is scheme://host:port without path; we
      # compose `<base>/<mount>/oauth/device/verify` so the URL works
      # regardless of where the engine is mounted.
      def verification_uri
        mount = Kiosk.configuration.mount_path
        "#{request.base_url}#{mount}/oauth/device/verify"
      end

      def render_oauth_error(code, description, status:)
        Kiosk::Server::Headers.add_to(response.headers)
        render json: { error: code.to_s, error_description: description }, status: status
      end
    end
  end
end
