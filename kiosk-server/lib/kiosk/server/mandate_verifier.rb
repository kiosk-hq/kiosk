# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies agent-signed AP2 mandate JWS and builds the value objects.
    #
    # Trust model for every mandate in the chain (intent, cart):
    #   * Signature key = the *registered* agent's public key (looked up by
    #     the authenticated agent_id — a revoked agent has no key).
    #   * `iss` MUST equal the provider's own issuer (forged-provenance guard).
    #   * The mandate is bound to the AUTHENTICATED principal: the payload's
    #     `agent_id`/`user_id` must match the verified {Kiosk::Identity}, not
    #     just be internally consistent — an agent cannot sign on behalf of a
    #     different principal than the one it authenticated as.
    #   * `exp` is REQUIRED — an unexpiring mandate is rejected outright.
    #
    # `verify_cart` additionally enforces the AP2 spending envelope: the cart
    # must reference the presented intent and stay within its cap.
    module MandateVerifier
      module_function

      # Verify an IntentMandate JWS → {Kiosk::Mandate::IntentMandate}.
      def verify_intent(raw_jws:, identity:)
        payload = decode_and_check(raw_jws, identity)

        Kiosk::Mandate::IntentMandate.new(
          id: payload[:id], user_id: payload[:user_id], agent_id: payload[:agent_id],
          issuer: payload[:iss], scope: payload[:scope],
          cap_amount_cents: payload[:cap_amount_cents], currency: payload[:currency],
          expires_at: (Time.at(payload[:exp]) if payload[:exp]),
          created_at: (Time.at(payload[:iat]) if payload[:iat]),
          raw_jws: raw_jws,
        )
      end

      # Verify a CartMandate JWS → {Kiosk::Mandate::CartMandate}, enforcing
      # that it is bound to `intent` and stays within the intent's cap.
      def verify_cart(raw_jws:, identity:, intent:)
        payload = decode_and_check(raw_jws, identity)

        cart = Kiosk::Mandate::CartMandate.new(
          id: payload[:id], intent_mandate_id: payload[:intent_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          line_items: payload[:line_items], total_amount_cents: payload[:total_amount_cents],
          currency: payload[:currency],
          expires_at: (Time.at(payload[:exp]) if payload[:exp]),
          created_at: (Time.at(payload[:iat]) if payload[:iat]),
          raw_jws: raw_jws,
        )

        unless cart.intent_mandate_id == intent.id
          raise Errors::Forbidden.new("cart not bound to the intent",
                                      hint: "expected intent_mandate_id #{intent.id.inspect}")
        end
        if cart.total_amount_cents.to_i > intent.cap_amount_cents.to_i
          raise Errors::Forbidden.new(
            "cart total exceeds intent cap",
            hint: "cart #{cart.total_amount_cents} > cap #{intent.cap_amount_cents}",
          )
        end

        cart
      end

      # Decode + verify the JWS and run the checks shared by every mandate
      # in the chain. Returns the symbol-keyed payload Hash.
      #
      # `required_claims: ["exp"]` makes a mandate with no expiry fail at
      # decode time (JWT::MissingRequiredClaim) rather than silently passing
      # as a non-expiring credential.
      def decode_and_check(raw_jws, identity)
        key    = AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(identity.agent_id)
        issuer = Kiosk.configuration.issuer
        payload, = ::JWT.decode(raw_jws, key, true, algorithms: ["RS256"], required_claims: ["exp"])
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != issuer
          raise Errors::Forbidden.new("mandate issuer mismatch", hint: "expected #{issuer.inspect}")
        end
        unless payload[:agent_id] == identity.agent_id && payload[:user_id] == identity.user_id
          raise Errors::Forbidden.new(
            "mandate principal mismatch",
            hint: "mandate must be signed for the authenticated agent/user",
          )
        end

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("mandate expired")
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Forbidden.new("mandate missing exp")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("mandate signature invalid: #{e.message}")
      end
      private_class_method :decode_and_check
    end
  end
end
