# frozen_string_literal: true

require "json"
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
        # The binary KYC gate. A KYC-restricted Action (e.g. skooti's
        # `rent_motorcycle`, the registered gate that resolves the K-346
        # `unlock`-gate reference) calls this, or the finer-grained
        # {#kyc_has_attributes?} when it needs specific booleans.
        def kyc_verified?(agent_id)
          row = ActiveRecord::Base.connection.execute(
            "SELECT kyc_verified_at FROM #{schema}.agents WHERE id = #{quote(agent_id)} AND revoked_at IS NULL",
          ).first
          return false if row.nil?

          !row.fetch("kyc_verified_at", nil).nil?
        end

        # Returns the NAMED ANONYMIZED boolean attributes a valid attestation
        # granted this agent — a String-keyed hash like
        # `{"age_over_18" => true, "licence_a" => true}`. Empty `{}` when the
        # agent verified with a bare binary attestation, or when no attestation
        # is on file / the agent is unknown. Only booleans were ever stored —
        # never the DOB, licence number, or any document (the anonymized point).
        def kyc_attributes(agent_id)
          row = ActiveRecord::Base.connection.execute(
            "SELECT kyc_attributes FROM #{schema}.agents WHERE id = #{quote(agent_id)} AND revoked_at IS NULL",
          ).first
          return {} if row.nil?

          raw = row.fetch("kyc_attributes", nil)
          return {} if raw.nil?

          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
          parsed.is_a?(Hash) ? parsed : {}
        end

        # Returns true iff EVERY name in `required` is present-and-true in the
        # agent's stored KYC attributes. `required` is a list of attribute
        # names (Strings/Symbols). Used by an attribute-gated Action, e.g.
        # `rent_motorcycle` requiring both `age_over_18` and `licence_a`.
        def kyc_has_attributes?(agent_id, required)
          attrs = kyc_attributes(agent_id)
          Array(required).all? { |name| attrs[name.to_s] == true }
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
