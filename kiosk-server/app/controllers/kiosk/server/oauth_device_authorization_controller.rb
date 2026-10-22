# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # POST <endpoint>/oauth/device_authorization (RFC 8628 §3.1): a registered
    # client opens the claim half of account binding. It authenticates with a
    # client assertion, so it sends no `client_id` of its own.
    class OauthDeviceAuthorizationController < ::ActionController::API
      include BindingModuleGate
      include OauthAnswers

      prepend_before_action :refuse_unserved_binding

      def create
        problem = role_problem
        raise OauthError.new(:invalid_request, problem) if problem

        render_oauth(device_authorization(DeviceCodeGrant.start(client: authenticate_client!)))
      rescue OauthError => e
        render_oauth_error(e)
      end

      private

      # A `role` is refused: the role is the approving human's, and the
      # assistant does not choose it. A `scope` is ignored (RFC 6749 Section
      # 3.3): an assistant gets another role only when a human who holds that
      # role binds it to their account, or through the identity provider.
      def role_problem
        return unless params.key?(:role)

        'role is not accepted here: an assistant does not choose its own role. ' \
          'The role of a bound assistant is the role of the account holder who approves, ' \
          "and this provider's identity system gives it at the verify page."
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
    end
  end
end
