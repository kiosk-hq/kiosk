# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # POST <endpoint>/oauth/device_authorization (RFC 8628 §3.1): an assistant
    # opens the claim half of account binding with `client_id` and `public_key`.
    class OauthDeviceAuthorizationController < ::ActionController::API
      include BindingModuleGate

      prepend_before_action :refuse_unserved_binding

      def create
        problem = request_problem
        return render_oauth_error(:invalid_request, problem, status: 400) if problem

        result = DeviceCodeGrant.start(client_id: params[:client_id].to_s, public_key_pem: params[:public_key].to_s)
        Kiosk::Server::Headers.add_to(response.headers)
        render json: device_authorization(result)
      end

      private

      # The first reason this request is refused, or nil.
      def request_problem
        return 'client_id parameter required' if params[:client_id].to_s.empty?
        return 'public_key parameter required' if params[:public_key].to_s.empty?

        key_problem(params[:public_key].to_s) || role_problem
      end

      def key_problem(public_key)
        PopVerifier.load_public_key(public_key.strip)
        nil
      rescue Errors::BadRequest => e
        e.message
      end

      # Refused, not ignored: the role is the approving human's, and this
      # request is unauthenticated.
      def role_problem
        offending = %i[role scope].find { |name| params.key?(name) }
        return unless offending

        "#{offending} is not accepted here — an assistant does not choose its own role. " \
          "The role of a bound assistant is the approving account holder's own role, " \
          "read from this provider's identity system when they approve at the verify page."
      end

      def device_authorization(result)
        {
          device_code: result[:device_code],
          user_code: result[:user_code],
          verification_uri: verification_uri,
          verification_uri_complete: "#{verification_uri}?user_code=#{result[:user_code]}",
          expires_in: result[:expires_in],
          interval: result[:interval]
        }
      end

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
