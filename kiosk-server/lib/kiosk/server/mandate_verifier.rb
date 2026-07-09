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
    #   * All of `id, user_id, agent_id, iss, iat, exp` are REQUIRED (presence
    #     enforced at decode; `exp` also rejects an unexpiring mandate). A
    #     mandate missing any of them is rejected outright.
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

      # Verify a PaymentMandate JWS → {Kiosk::Mandate::PaymentMandate},
      # enforcing that it is bound to `cart` and matches its amount/currency.
      #
      # `payment_method` is OPTIONAL: in the SetupIntent model the assistant
      # authorises the charge but never presents a card — the provider's PSP
      # resolves the principal's on-file card.  Adapters that do require an
      # explicit PM (StubPsp, early tests) still send one; the field is simply
      # no longer rejected when absent.
      def verify_payment(raw_jws:, identity:, cart:)
        payload = decode_and_check(raw_jws, identity)

        unless payload[:cart_mandate_id] == cart.id
          raise Errors::Forbidden.new("payment not bound to the cart")
        end
        unless payload[:amount_cents].to_i == cart.total_amount_cents.to_i &&
               payload[:currency] == cart.currency
          raise Errors::Forbidden.new("payment amount/currency does not match cart")
        end

        Kiosk::Mandate::PaymentMandate.new(
          id: payload[:id], cart_mandate_id: payload[:cart_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          payment_method: payload[:payment_method],
          amount_cents: payload[:amount_cents], currency: payload[:currency],
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

      # Every mandate MUST carry these claims (spec, AP2 mandate section).
      # Presence is enforced at decode time; `iss`/`user_id`/`agent_id` are
      # additionally value-checked below. `id` and `iat` are presence-only:
      # without this list a mandate missing `id` or `iat` decoded and passed
      # silently (only `exp` was previously required).
      REQUIRED_CLAIMS = %w[id user_id agent_id iss iat exp].freeze

      # Decode + verify the JWS and run the checks shared by every mandate
      # in the chain. Returns the symbol-keyed payload Hash.
      def decode_and_check(raw_jws, identity)
        key    = AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(identity.agent_id)
        issuer = Kiosk.configuration.issuer
        payload, = ::JWT.decode(raw_jws, key, true, algorithms: ["RS256"], required_claims: REQUIRED_CLAIMS)
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
      rescue ::JWT::MissingRequiredClaim => e
        raise Errors::Forbidden.new("mandate missing required claim: #{e.message}")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("mandate signature invalid: #{e.message}")
      end
      private_class_method :decode_and_check
    end
  end
end
