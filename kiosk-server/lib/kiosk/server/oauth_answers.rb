# frozen_string_literal: true

module Kiosk
  module Server
    # The answers of the `/oauth/*` endpoints: JSON that no cache keeps
    # (RFC 6749 Section 5.1), and `{error, error_description}` for a refusal.
    module OauthAnswers
      private

      def render_oauth(body, status: :ok)
        Headers.add_to(response.headers)
        response.set_header('Cache-Control', 'no-store')
        render json: body, status: status
      end

      def render_oauth_error(error)
        render_oauth(error.to_h, status: error.status)
      end

      # The client that the request's client assertion authenticates.
      # @raise [OauthError] `invalid_client`
      def authenticate_client!
        ClientAssertion.authenticate!(params[:client_assertion_type].to_s, params[:client_assertion].to_s,
                                      client_id: params[:client_id].presence)
      rescue ClientAssertion::Refused => e
        raise e.to_oauth
      end
    end
  end
end
