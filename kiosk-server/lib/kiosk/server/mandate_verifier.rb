# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies agent-signed AP2 mandate JWS and builds the value objects.
    # Signature key = the registered agent's public key; iss MUST equal the
    # provider's own issuer (forged-provenance guard).
    module MandateVerifier
      module_function

      def verify_cart(raw_jws:, agent_id:)
        key    = AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(agent_id)
        issuer = Kiosk.configuration.issuer
        payload, = ::JWT.decode(raw_jws, key, true, algorithms: ["RS256"])
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != issuer
          raise Errors::Forbidden.new("mandate issuer mismatch", hint: "expected #{issuer.inspect}")
        end

        Kiosk::Mandate::CartMandate.new(
          id: payload[:id], intent_mandate_id: payload[:intent_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          line_items: payload[:line_items], total_amount_cents: payload[:total_amount_cents],
          currency: payload[:currency],
          expires_at: (Time.at(payload[:exp]) if payload[:exp]),
          created_at: (Time.at(payload[:iat]) if payload[:iat]),
          raw_jws: raw_jws,
        )
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("mandate expired")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("mandate signature invalid: #{e.message}")
      end
    end
  end
end
