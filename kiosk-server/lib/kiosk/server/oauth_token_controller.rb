# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::API)` guard below means it only defines
# the controller when ActionController::API is present. In plain Ruby the
# require is a no-op. The engine draws the route when Rails is present.

if defined?(::ActionController::API)
  require "kiosk/server/device_code_grant"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # POST <endpoint>/oauth/token — the polling end of the claim
      # ceremony. See RFC 6749 §3.2 (token endpoint) + RFC 8628 §3.4
      # (device_code grant). Only the device_code grant is served: the
      # endpoint completes the account binding; it is not a
      # general OAuth token service — kiosk-pop remains the only auth
      # story, and the JWT returned here is minted through the very same
      # DefaultAgentIdp path as /auth/login.
      #
      # Request: `application/x-www-form-urlencoded`
      #   grant_type   required — `urn:ietf:params:oauth:grant-type:device_code`
      #   device_code  required
      #   signed       required once approved — compact RS256 JWS over
      #                {aud, nonce, jti} proving possession of the key the
      #                ceremony binds (BIND-POP; same handshake as
      #                register/login: GET /auth/challenge first)
      #
      # Success response (200):
      #   { "access_token": "<kiosk-pop JWT>", "token_type": "Bearer",
      #     "expires_in": 3600, "scope": "customer" }
      #
      # Error response (400; 401 for invalid_client) per RFC 6749 §5.2 +
      # RFC 8628 §3.5:
      #   { "error": "authorization_pending" | "slow_down"
      #            | "access_denied"          | "expired_token"
      #            | "invalid_grant"          | "invalid_client"
      #            | "invalid_request"        | "unsupported_grant_type",
      #     "error_description": "..." }
      class OauthTokenController < ::ActionController::API
        def create
          grant_type = params[:grant_type].to_s
          case grant_type
          when DeviceCodeGrant::GRANT_TYPE
            handle_device_code_grant
          when ""
            render_oauth_error(:invalid_request, "grant_type required", status: 400)
          else
            render_oauth_error(:unsupported_grant_type,
                               "only the device_code grant is served here — " \
                               "kiosk-pop (POST /auth/login) is the token-refresh path",
                               status: 400)
          end
        end

        private

        def handle_device_code_grant
          result = DeviceCodeGrant.exchange(
            device_code: params[:device_code].to_s,
            signed:      params[:signed],
          )

          Kiosk::Server::Headers.add_to(response.headers)
          if result[:ok]
            body = {
              access_token: result[:access_token],
              token_type:   result[:token_type],
              expires_in:   result[:expires_in],
            }
            body[:scope] = result[:scope] if result[:scope]
            render json: body
          else
            # RFC 6749 §5.2: invalid_client — the possession proof failed —
            # is the one error the server SHOULD signal with 401.
            status = result[:error] == "invalid_client" ? 401 : 400
            render json: {
              error:             result[:error],
              error_description: result[:description],
            }, status: status
          end
        end

        def render_oauth_error(code, description, status:)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: { error: code.to_s, error_description: description }, status: status
        end
      end
    end
  end
end
