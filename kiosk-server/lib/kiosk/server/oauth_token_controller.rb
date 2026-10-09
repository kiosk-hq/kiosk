# frozen_string_literal: true

require "action_controller"
require "kiosk/server/device_code_grant"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST <endpoint>/oauth/token: the assistant polls the claim ceremony
    # (RFC 8628 §3.4). Only the device_code grant is served.
    class OauthTokenController < ::ActionController::API
      include BindingModuleGate
      prepend_before_action :refuse_unserved_binding

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
