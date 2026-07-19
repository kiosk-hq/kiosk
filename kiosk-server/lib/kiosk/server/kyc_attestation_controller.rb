# frozen_string_literal: true

# Conditionally defined — only available inside a Rails host, same pattern
# as WireController and AuthController.

if defined?(::ActionController::API)
  require "json"
  require "kiosk/server/kyc_verifier"
  require "kiosk/server/errors"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # POST /kiosk/agents/kyc
      #
      # Authenticates the agent (via Bearer token), verifies the submitted KYC
      # attestation JWS, and records `kyc_verified_at = now()` on the agents
      # row.
      #
      # Request body: { "kyc_jws": "<compact JWS>" }
      # Success (200): { "kyc_verified": true }
      # Failure (400/401/403): error envelope from Kiosk::Server::Errors — 400
      # for a missing/malformed/non-object JSON body or a missing kyc_jws field
      # 401 for a missing/invalid agent token, 403 for a failed KYC
      # verification.
      class KycAttestationController < ::ActionController::API
        def create
          identity = authenticate!
          body     = parse_body!
          raw_jws  = body[:kyc_jws] or raise Errors::BadRequest.new("missing field: kyc_jws")

          KycVerifier.verify(raw_jws: raw_jws, identity: identity)
          mark_kyc_verified!(identity.agent_id)

          Kiosk::Server::Headers.add_to(response.headers)
          render json: { kyc_verified: true }, status: :ok
        rescue Errors::Base => e
          render_error(e)
        end

        private

        # Parse the request body as a JSON object. Mirrors
        # WireController/AuthController#parse_body!: an empty body, malformed
        # JSON, or a non-object (scalar/array) body is a 400 BadRequest, never
        # a 500 — previously the bare JSON.parse ran outside the Errors::Base
        # rescue, so JSON::ParserError / TypeError (body[:kyc_jws] on an Array)
        # leaked as an unhandled 500.
        def parse_body!
          raw = request.raw_post
          raise Errors::BadRequest, "request body must be a JSON object" if raw.nil? || raw.empty?

          parsed = JSON.parse(raw, symbolize_names: true)
          raise Errors::BadRequest, "request body must be a JSON object" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError => e
          raise Errors::BadRequest, "invalid JSON body: #{e.message}"
        end

        # KYC attestation is an AGENT-only surface: the effective agent IdP
        # (configured override or the bundled default; without this,
        # providers with a custom idp were locked out by a hardcoded
        # DefaultAgentIdp). No user_idp fallback — a web session must not
        # stamp an agent's kyc_verified_at.
        def authenticate!
          identity = IdentityResolution.agent_idp.verify(request)
          raise Errors::Unauthenticated.new("missing or invalid agent token") if identity.nil?

          identity
        end

        def mark_kyc_verified!(agent_id)
          conn   = ActiveRecord::Base.connection
          schema = Kiosk.configuration.schema
          conn.execute(
            "UPDATE #{conn.quote_table_name("#{schema}.agents")} " \
            "SET kyc_verified_at = now() " \
            "WHERE id = #{conn.quote(agent_id)} AND revoked_at IS NULL",
          )
        end

        def render_error(err)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: err.to_envelope, status: err.http_status
        end
      end
    end
  end
end
