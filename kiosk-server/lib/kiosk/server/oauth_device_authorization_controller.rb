# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests) by simply not loading this file when ActionController::API
# isn't around. Engine wires up the route when Rails is present.

if defined?(::ActionController::API)
  require "kiosk/server/device_code_grant"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # POST <endpoint>/oauth/device_authorization — RFC 8628 §3.1.
      # The CLI's first call in the `kiosk login` flow.
      #
      # Request: `application/x-www-form-urlencoded` (OAuth convention)
      #   client_id    required — identifier of the calling client
      #   scope        optional — synonym for `role`; OAuth-standard name
      #   role         optional — Kiosk extension; alias for `scope`
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

          requested_role = (params[:role] || params[:scope])&.to_s
          requested_role = nil if requested_role && requested_role.empty?

          # The requested role is CLIENT-chosen and ends up in the minted JWT,
          # so it must be validated against the provider's declared roles
          # (K-072, ADR-0011 principle: role assignment is provider-owned —
          # a client must never smuggle an arbitrary role claim).
          if requested_role && !Kiosk.configuration.roles.map(&:to_s).include?(requested_role)
            return render_oauth_error(
              :invalid_request,
              "unknown role #{requested_role.inspect} — not among this provider's roles",
              status: 400,
            )
          end

          result = DeviceCodeGrant.start(
            client_id:      client_id,
            requested_role: requested_role,
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
end
