# frozen_string_literal: true

require 'kiosk/agent_identity_providers/base'

module Kiosk
  module Server
    module AgentIdentityProviders
      # The bundled agent IdP: EdDSA tokens signed with the origin's own key and
      # bound to the agent's registered key (`cnf.jkt`); payment keys from the agents table.
      class DefaultAgentIdp < Kiosk::AgentIdentityProviders::Base
        def verify(request)
          token = Dpop.token(authorization_for(request))
          return nil if token.nil?

          claims = verified_claims(token)
          Kiosk::Identity.new(
            user_id: claims[:sub], role: claims[:role], actor: 'agent',
            agent_id: claims[:agent_id], claims: claims
          )
        rescue JwtIssuer::Error
          nil
        end

        def issue(agent_id:, role:)
          agent  = lookup_agent(agent_id)
          claims = { sub: agent.fetch('user_id'), agent_id: agent_id, actor: 'agent',
                     cnf: { jkt: AssistantKey.thumbprint(AssistantKey.from_pem(agent.fetch('public_key'))) } }
          claims[:role] = role.to_s unless role.nil? || role.to_s.empty?
          JwtIssuer.issue(
            claims: claims, audience: Kiosk.current_issuer, now: mint_instant(agent_id),
            expires_in: Kiosk.configuration.access_token_ttl
          )
        end

        def agent_payment_key(agent_id)
          pem = agent_row('public_key', agent_id)&.fetch('public_key', nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          AssistantKey.from_pem(pem)
        end

        private

        def verified_claims(token)
          JwtIssuer.verify(
            token: token,
            jwks: Jwks.build(keys: Kiosk.configuration.signing_keys),
            audience: Kiosk.current_issuer,
            issuer: Kiosk.current_issuer
          )
        end

        # Never earlier than the revocation watermark, so a token minted in the
        # second a rebind revoked (§6.3) still survives `iat < watermark`.
        def mint_instant(agent_id)
          now       = Time.current
          watermark = Kiosk.configuration.revocation_store.watermark_for(agent_id)
          return now if watermark.nil? || watermark <= now.to_i

          Time.at(watermark).utc
        end

        def lookup_agent(agent_id)
          row = agent_row('user_id, public_key', agent_id)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "unknown agent #{agent_id}" if row.nil?

          row
        end

        # `columns` is always a literal from this class, never caller input.
        def agent_row(columns, agent_id)
          ::ActiveRecord::Base.lease_connection.exec_query(
            "SELECT #{columns} FROM #{schema}.kiosk_agents WHERE id = $1 AND revoked_at IS NULL",
            "Kiosk agent #{columns}",
            [agent_id]
          ).to_a.first
        end

        def schema = Kiosk.configuration.schema

        def authorization_for(request)
          if request.respond_to?(:headers)
            request.headers['Authorization'] || request.headers['authorization']
          elsif request.is_a?(Hash)
            request['HTTP_AUTHORIZATION']
          end
        end
      end
    end
  end
end
