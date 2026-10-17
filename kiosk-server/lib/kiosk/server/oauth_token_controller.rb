# frozen_string_literal: true

require 'action_controller'
require 'kiosk/server/device_code_grant'
require 'kiosk/server/headers'

module Kiosk
  module Server
    # POST <endpoint>/oauth/token: the assistant polls the claim ceremony
    # (RFC 8628 §3.4). Only the device_code grant is served.
    class OauthTokenController < ::ActionController::API
      include BindingModuleGate

      prepend_before_action :refuse_unserved_binding

      UNSUPPORTED_GRANT = 'only the device_code grant is served here — ' \
                          'kiosk-pop (POST /auth/login) is the token-refresh path'

      def create
        case params[:grant_type].to_s
        when DeviceCodeGrant::GRANT_TYPE then handle_device_code_grant
        when '' then render_oauth_error(:invalid_request, 'grant_type required', status: 400)
        else render_oauth_error(:unsupported_grant_type, UNSUPPORTED_GRANT, status: 400)
        end
      end

      private

      def handle_device_code_grant
        result = DeviceCodeGrant.exchange(device_code: params[:device_code].to_s, signed: params[:signed])
        Kiosk::Server::Headers.add_to(response.headers)
        return render json: token_body(result) if result[:ok]

        # RFC 6749 §5.2: invalid_client — the possession proof failed —
        # is the one error the server SHOULD signal with 401.
        status = result[:error] == 'invalid_client' ? 401 : 400
        render json: { error: result[:error], error_description: result[:description] }, status: status
      end

      def token_body(result)
        body = { access_token: result[:access_token], token_type: result[:token_type], expires_in: result[:expires_in] }
        body[:scope] = result[:scope] if result[:scope]
        body
      end

      def render_oauth_error(code, description, status:)
        Kiosk::Server::Headers.add_to(response.headers)
        render json: { error: code.to_s, error_description: description }, status: status
      end
    end
  end
end
