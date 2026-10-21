# frozen_string_literal: true

require 'action_controller'
require 'json'

module Kiosk
  module Server
    # POST <endpoint>/oauth/register (RFC 7591 Section 3): open registration of
    # an AI assistant's public key. The optional toll's proofs ride in the
    # `Kiosk-PoW` header, so the body stays the same on retry.
    class OauthRegistrationController < ::ActionController::API
      include AuthController::Answers
      include AuthController::Proofs
      include OauthAnswers

      def create
        client = ClientRegistration.call(metadata, pow: proofs)
        render_oauth(client.information, status: :created)
      rescue OauthError => e
        render_oauth_error(e)
      rescue Errors::Base => e
        render_error(e)
      end

      private

      def metadata
        JSON.parse(request.raw_post.to_s)
      rescue JSON::ParserError
        raise OauthError.new(:invalid_client_metadata, 'the request body must be a JSON object')
      end
    end
  end
end
