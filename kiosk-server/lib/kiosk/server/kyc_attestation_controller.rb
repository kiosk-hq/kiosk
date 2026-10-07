# frozen_string_literal: true

require "action_controller"
require "json"
require "kiosk/server/kyc"
require "kiosk/server/kyc_verifier"
require "kiosk/server/request_validation"
require "kiosk/server/errors"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST <endpoint>/agents/kyc `{kyc_jws}`: verifies an assistant-submitted
    # attestation and replaces its principal's grants ({Kyc.grant!}). Refusals
    # are problem documents: 400 body, 401 token, 403 attestation.
    class KycAttestationController < ::ActionController::API
      def create
        identity = authenticate!
        body     = parse_body!("POST <endpoint>/agents/kyc")
        raw_jws  = body[:kyc_jws] or raise Errors.missing_field("kyc_jws")

        claims = KycVerifier.verify(raw_jws: raw_jws, subject: identity.user_id)
        Kyc.grant!(identity.user_id, claims[:attributes])

        Kiosk::Server::Headers.add_to(response.headers)
        render json: { kyc_verified: true, attributes: claims[:attributes] || {} }, status: :ok
      rescue Errors::Base => e
        render_error(e)
      end

      private

      # A JSON object held to the shape §17 publishes for `exchange`, else 400.
      def parse_body!(exchange)
        raw = request.raw_post
        raise Errors::BadRequest, "request body must be a JSON object" if raw.nil? || raw.empty?

        parsed = JSON.parse(raw, symbolize_names: true)
        raise Errors::BadRequest, "request body must be a JSON object" unless parsed.is_a?(Hash)

        RequestValidation.validate_body!(parsed, exchange: exchange)
        parsed
      rescue JSON::ParserError
        raise Errors.malformed_json
      end

      # Only an assistant submits an attestation, so only the agent IdP answers.
      def authenticate!
        identity = IdentityResolution.agent_idp.verify(request)
        raise Errors::Unauthenticated.new("missing or invalid agent token") if identity.nil?

        identity
      end

      def render_error(err)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: err.http_status
        )
        err.response_headers.each { |name, value| response.set_header(name, value) }
        render json: err.to_problem, status: err.http_status,
               content_type: Errors::PROBLEM_CONTENT_TYPE
      end
    end
  end
end
