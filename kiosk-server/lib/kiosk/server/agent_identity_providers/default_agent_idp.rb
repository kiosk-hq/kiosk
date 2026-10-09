# frozen_string_literal: true

require "kiosk/agent_identity_providers/base"

module Kiosk
  module Server
    module AgentIdentityProviders
      # The bundled agent IdP: RS256 tokens signed with the origin's own key;
      # payment keys from the agents table.
      class DefaultAgentIdp < Kiosk::AgentIdentityProviders::Base
        def verify(request)
          header = authorization_for(request)
          return nil if header.nil? || header.empty?

          token  = header.sub(/\ABearer\s+/i, "")
          config = Kiosk.configuration
          claims = JwtIssuer.verify(
            token:    token,
            jwks:     Jwks.build(keys: [config.signing_key]),
            audience: Kiosk.current_issuer,
            issuer:   Kiosk.current_issuer,
          )
          Kiosk::Identity.new(
            user_id:  claims[:sub], role: claims[:role], actor: "agent",
            agent_id: claims[:agent_id], claims: claims,
          )
        rescue JwtIssuer::Error
          nil
        end

        def issue(agent_id:, role:)
          claims = { sub: lookup_user_id(agent_id), agent_id: agent_id, actor: "agent" }
          claims[:role] = role.to_s unless role.nil? || role.to_s.empty?
          JwtIssuer.issue(
            claims: claims, audience: Kiosk.current_issuer, now: mint_instant(agent_id),
          )
        end

        def agent_payment_key(agent_id)
          pem = agents_column("public_key", agent_id)&.fetch("public_key", nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          OpenSSL::PKey::RSA.new(pem)
        end

        private

        # Never earlier than the revocation watermark, so a token minted in the
        # second a rebind revoked (§6.3) still survives `iat < watermark`.
        def mint_instant(agent_id)
          now   = Time.now
          store = Kiosk.configuration.revocation_store
          return now unless store.respond_to?(:watermark_for)

          watermark = store.watermark_for(agent_id)
          return now if watermark.nil? || watermark <= now.to_i

          Time.at(watermark)
        end

        def lookup_user_id(agent_id)
          row = agents_column("user_id", agent_id)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "unknown agent #{agent_id}" if row.nil?

          row.fetch("user_id")
        end

        # `column` is always a literal from this class, never caller input.
        def agents_column(column, agent_id)
          ::ActiveRecord::Base.lease_connection.exec_query(
            "SELECT #{column} FROM #{schema}.agents WHERE id = $1 AND revoked_at IS NULL",
            "Kiosk agent #{column}",
            [agent_id],
          ).to_a.first
        end

        def schema = Kiosk.configuration.schema

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
