# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::API)` guard below means it only defines
# the controller when ActionController::API is present. In plain Ruby the
# require is a no-op. Engine wires up the route when Rails is present.

if defined?(::ActionController::API)
  require "kiosk/server/device_code_grant"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # POST <endpoint>/oauth/token — multi-grant OAuth token endpoint.
      # See RFC 6749 §3.2 (token endpoint) + RFC 8628 §3.4 (device_code
      # grant). Other grants (authorization_code with PKCE, refresh_token)
      # land in follow-up sub-slices.
      #
      # Request: `application/x-www-form-urlencoded`
      #   grant_type   required — `urn:ietf:params:oauth:grant-type:device_code`
      #   device_code  required when grant_type is device_code
      #
      # Success response (200):
      #   { "access_token": "<JWT>", "token_type": "Bearer",
      #     "expires_in": 3600, "scope": "customer" }
      #
      # Error response (400 / 401) per RFC 6749 §5.2 + RFC 8628 §3.5:
      #   { "error": "authorization_pending" | "access_denied"
      #            | "expired_token"          | "invalid_grant"
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
          when "authorization_code"
            render_oauth_error(:unsupported_grant_type,
                               "authorization_code (PKCE) lands in a follow-up release",
                               status: 400)
          when "refresh_token"
            render_oauth_error(:unsupported_grant_type,
                               "refresh_token grant lands in a follow-up release",
                               status: 400)
          else
            render_oauth_error(:unsupported_grant_type,
                               "unknown grant_type: #{grant_type}",
                               status: 400)
          end
        end

        private

        def handle_device_code_grant
          result = DeviceCodeGrant.exchange(device_code: params[:device_code].to_s)

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
            render json: {
              error:             result[:error],
              error_description: result[:description],
            }, status: 400
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
