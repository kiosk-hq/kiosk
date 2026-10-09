# frozen_string_literal: true

require "action_controller"
require "kiosk/server/device_code_grant"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST <endpoint>/oauth/device_authorization (RFC 8628 §3.1): an assistant
    # opens the claim half of account binding with `client_id` and `public_key`.
    class OauthDeviceAuthorizationController < ::ActionController::API
      include BindingModuleGate
      prepend_before_action :refuse_unserved_binding

      def create
        client_id = params[:client_id].to_s
        if client_id.empty?
          return render_oauth_error(:invalid_request, "client_id parameter required", status: 400)
        end

        public_key = params[:public_key].to_s
        if public_key.empty?
          return render_oauth_error(:invalid_request, "public_key parameter required", status: 400)
        end
        begin
          PopVerifier.load_public_key(public_key.strip)
        rescue Errors::BadRequest => e
          return render_oauth_error(:invalid_request, e.message, status: 400)
        end

        # Refused, not ignored: the role is the approving human's, and this
        # request is unauthenticated.
        if (offending = %i[role scope].find { |name| params.key?(name) })
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
