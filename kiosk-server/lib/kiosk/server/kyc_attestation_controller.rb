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
      # Failure (401/403): error envelope from Kiosk::Server::Errors.
      class KycAttestationController < ::ActionController::API
        def create
          identity = authenticate!
          body     = JSON.parse(request.raw_post, symbolize_names: true)
          raw_jws  = body[:kyc_jws] or raise Errors::BadRequest.new("missing field: kyc_jws")

          KycVerifier.verify(raw_jws: raw_jws, identity: identity)
          mark_kyc_verified!(identity.agent_id)

          Kiosk::Server::Headers.add_to(response.headers)
          render json: { kyc_verified: true }, status: :ok
        rescue Errors::Base => e
          render_error(e)
        end

        private

        def authenticate!
          idp = AgentIdentityProviders::DefaultAgentIdp.new
          identity = idp.verify(request)
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
