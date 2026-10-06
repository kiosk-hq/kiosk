# frozen_string_literal: true

# The KYC attestation surface, same shape as WireController and AuthController.

require "action_controller"
require "json"
require "kiosk/server/kyc"
require "kiosk/server/kyc_verifier"
require "kiosk/server/request_validation"
require "kiosk/server/errors"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST /kiosk/agents/kyc
    #
    # Authenticates the agent (via Bearer token), verifies the submitted KYC
    # attestation JWS, and replaces its principal's grants with the attributes
    # it carries ({Kyc.grant!}).
    #
    # Request body: { "kyc_jws": "<compact JWS>" }
    # Success (200): { "kyc_verified": true }
    # Failure (400/401/403): an RFC 9457 problem document raised from
    # Kiosk::Server::Errors and served as `application/problem+json` — 400
    # for a missing/malformed/non-object JSON body or a missing kyc_jws field
    # 401 for a missing/invalid agent token, 403 for a failed KYC
    # verification.
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

      # Parse the request body as a JSON object. Mirrors
      # WireController/AuthController#parse_body!: an empty body, malformed
      # JSON, or a non-object (scalar/array) body is a 400 BadRequest, never
      # a 500. That is why this runs INSIDE the Errors::Base rescue and raises
      # its own typed error: a bare JSON.parse outside it leaks
      # JSON::ParserError — or TypeError, from `body[:kyc_jws]` on an Array —
      # as an unhandled 500.
      # See {AuthController#parse_body!}: the body is held to the object
      # §17 publishes for `exchange` before the member below is read.
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

      # KYC attestation is an AGENT-only surface: the effective agent IdP
      # (configured override or the bundled default; without this,
      # providers with a custom idp were locked out by a hardcoded
      # DefaultAgentIdp). No user_idp fallback: only an AI assistant
      # submits an attestation.
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
