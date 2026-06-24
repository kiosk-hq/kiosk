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
        end

        def issue(agent_id:, role:)
          JwtIssuer.issue(
            claims:   { sub: lookup_user_id(agent_id), agent_id: agent_id, role: role.to_s, actor: "agent" },
            audience: Kiosk.configuration.issuer,
          )
        end

        def agent_payment_key(agent_id)
          pem = ActiveRecord::Base.connection.execute(
            "SELECT public_key FROM #{schema}.agents WHERE id = #{quote(agent_id)}",
          ).first&.fetch("public_key", nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          OpenSSL::PKey::RSA.new(pem)
        end

        private

        def lookup_user_id(agent_id)
          row = ActiveRecord::Base.connection.execute(
            "SELECT user_id FROM #{schema}.agents WHERE id = #{quote(agent_id)}",
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
            request["HTTP_AUTHORIZATION"] || request[:authorization]
          elsif request.is_a?(String)
            request
          end
        end
      end
    end
  end
end
