# frozen_string_literal: true

require "kiosk/agent_identity_providers/base"

module Kiosk
  module Server
    module AgentIdentityProviders
      # Bundled agent-IdP: verifies/issues RS256 JWTs against the provider's
      # own signing key; resolves agent payment keys from kiosk.agents.
      class DefaultAgentIdp < Kiosk::AgentIdentityProviders::Base
        def verify(request)
          header = authorization_for(request)
          return nil if header.nil? || header.empty?

          token  = header.sub(/\ABearer\s+/i, "")
          config = Kiosk.configuration
          claims = JwtIssuer.verify(
            token:    token,
            jwks:     Jwks.build(keys: [config.signing_key]),
            audience: config.issuer,
            issuer:   config.issuer,
          )
          Kiosk::Identity.new(
            user_id:  claims[:sub], role: claims[:role], actor: "agent",
            agent_id: claims[:agent_id], claims: claims,
          )
        rescue JwtIssuer::Error
          # Expired, revoked, wrongly-signed, or malformed tokens resolve to
          # nil — the controller turns nil into 401 Unauthenticated. Letting
          # the error escape here surfaced as an HTTP 500.
          nil
        end

        def issue(agent_id:, role:)
          claims = { sub: lookup_user_id(agent_id), agent_id: agent_id, actor: "agent" }
          # Role-less principals get NO role claim — an empty-string
          # claim would round-trip into an unusable Identity.
          claims[:role] = role.to_s unless role.nil? || role.to_s.empty?
          JwtIssuer.issue(claims: claims, audience: Kiosk.configuration.issuer)
        end

        def agent_payment_key(agent_id)
          pem = ActiveRecord::Base.connection.execute(
            "SELECT public_key FROM #{schema}.agents WHERE id = #{quote(agent_id)} AND revoked_at IS NULL",
          ).first&.fetch("public_key", nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          OpenSSL::PKey::RSA.new(pem)
        end

        # Returns true iff the agent has a non-NULL `kyc_verified_at` timestamp.
        # Used by the `unlock` Action gate and any other KYC-restricted Action.
        def kyc_verified?(agent_id)
          row = ActiveRecord::Base.connection.execute(
            "SELECT kyc_verified_at FROM #{schema}.agents WHERE id = #{quote(agent_id)} AND revoked_at IS NULL",
          ).first
          return false if row.nil?

          !row.fetch("kyc_verified_at", nil).nil?
        end

        private

        def lookup_user_id(agent_id)
          row = ActiveRecord::Base.connection.execute(
            "SELECT user_id FROM #{schema}.agents WHERE id = #{quote(agent_id)} AND revoked_at IS NULL",
          ).first
          raise Kiosk::AgentIdentityProviders::InvalidToken, "unknown agent #{agent_id}" if row.nil?

          row.fetch("user_id")
        end

        def schema = Kiosk.configuration.schema
        def quote(value) = ActiveRecord::Base.connection.quote(value)

        def authorization_for(request)
          if request.respond_to?(:headers)
            request.headers["Authorization"] || request.headers["authorization"]
          elsif request.is_a?(Hash)
            request["HTTP_AUTHORIZATION"]
          end
        end
      end
    end
  end
end
