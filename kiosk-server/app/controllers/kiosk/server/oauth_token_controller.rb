# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # POST <endpoint>/oauth/token (RFC 6749 Section 3.2): a registered client
    # authenticates with a client assertion (RFC 7523) and a DPoP proof of its
    # registered key (RFC 9449), and gets an access token bound to that key.
    # The client_credentials grant is always served; the device-code grant
    # (RFC 8628 Section 3.4) only where the origin serves account binding.
    class OauthTokenController < ::ActionController::API
      include AuthController::Answers
      include AuthController::Proofs
      include OauthAnswers

      def create
        case params[:grant_type].to_s
        when Client::CLIENT_CREDENTIALS then render_token(authenticated_client)
        when Client::DEVICE_CODE then device_code_grant
        when '' then raise OauthError.new(:invalid_request, 'grant_type required')
        else raise OauthError.new(:unsupported_grant_type, unsupported_grant)
        end
      rescue OauthError => e
        render_oauth_error(e)
      rescue Errors::Base => e
        render_error(e)
      end

      private

      # The toll comes before the client authenticates and before the code is read.
      def device_code_grant
        device_code = params[:device_code].to_s
        raise OauthError.new(:unsupported_grant_type, unsupported_grant) unless Kiosk.configuration.serve_account_binding
        raise OauthError.new(:invalid_request, 'device_code parameter required') if device_code.empty?

        DeviceCodeGrant.pay_toll!(device_code, proofs)
        render_token(DeviceCodeGrant.exchange(device_code: device_code, client: authenticated_client))
      end

      def unsupported_grant = "the grant types served here are #{Client.grant_types.join(', ')}"

      # The client assertion, then the DPoP proof of the registered key.
      def authenticated_client
        client = authenticate_client!
        Dpop.verify_token_request!(request.headers['DPoP'], jkt: client.thumbprint, url: "#{Kiosk.current_issuer}#{request.path}")
        client
      end

      # RFC 6749 Section 5.1. The scope is the role of the client.
      def render_token(client)
        token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: client.id, role: client.role)
        body = { access_token: token, token_type: Dpop::SCHEME, expires_in: Kiosk.configuration.access_token_ttl }
        body[:scope] = client.role if client.role
        render_oauth(body)
      end
    end
  end
end
