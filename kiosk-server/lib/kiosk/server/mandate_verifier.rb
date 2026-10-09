# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies the agent-signed AP2 mandate chain (intent → cart → payment):
    # signed by the authenticated agent's key, issued for this origin, bound to
    # the authenticated principal, and within the intent's cap.
    module MandateVerifier
      # §11.1: an ISO 4217 alpha-3 code, matched after {canonical_currency}.
      CURRENCY_CODE = /\A[a-z]{3}\z/

      module_function

      def verify_intent(raw_jws:, identity:)
        payload = decode_and_check(raw_jws, identity)
        require_amount!(payload, :cap_amount_cents)
        currency = require_currency!(payload)

        Kiosk::Mandate::IntentMandate.new(
          id: payload[:id], user_id: payload[:user_id], agent_id: payload[:agent_id],
          issuer: payload[:iss], scope: payload[:scope],
          cap_amount_cents: payload[:cap_amount_cents], currency: currency,
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
          raw_jws: raw_jws,
        )
      end

      # `payment_method` is optional: the PSP charges the principal's card on file.
      def verify_payment(raw_jws:, identity:, cart:)
        payload = decode_and_check(raw_jws, identity)
        require_amount!(payload, :amount_cents)
        currency = require_currency!(payload)

        unless payload[:cart_mandate_id] == cart.id
          raise Errors::Forbidden.new("payment not bound to the cart")
        end
        unless payload[:amount_cents].to_i == cart.total_amount_cents.to_i &&
               currency == cart.currency
          raise Errors::Forbidden.new("payment amount/currency does not match cart")
        end

        Kiosk::Mandate::PaymentMandate.new(
          id: payload[:id], cart_mandate_id: payload[:cart_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          payment_method: payload[:payment_method],
          amount_cents: payload[:amount_cents], currency: currency,
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
          raw_jws: raw_jws,
        )
      end

      def verify_cart(raw_jws:, identity:, intent:)
        payload = decode_and_check(raw_jws, identity)
        require_amount!(payload, :total_amount_cents)
        currency = require_currency!(payload)
        require_line_items!(payload)

        cart = Kiosk::Mandate::CartMandate.new(
          id: payload[:id], intent_mandate_id: payload[:intent_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          line_items: payload[:line_items], total_amount_cents: payload[:total_amount_cents],
          currency: currency,
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
          raw_jws: raw_jws,
        )

        unless cart.intent_mandate_id == intent.id
          raise Errors::Forbidden.new("cart not bound to the intent",
                                      hint: "expected intent_mandate_id #{intent.id.inspect}")
        end
        # A cap is meaningless across currencies.
        if cart.currency != intent.currency
          raise Errors::Forbidden.new(
            "cart currency does not match intent cap currency",
            hint: "cart #{cart.currency.inspect} != intent #{intent.currency.inspect}",
          )
        end
        if cart.total_amount_cents.to_i > intent.cap_amount_cents.to_i
          raise Errors::Forbidden.new(
            "cart total exceeds intent cap",
            hint: "cart #{cart.total_amount_cents} > cap #{intent.cap_amount_cents}",
          )
        end

        cart
      end

      # Before any `.to_i`: nil, zero or negative would launder the cap.
      def require_amount!(payload, field)
        value = payload[field]
        if value.nil?
          raise Errors::Forbidden.new(
            "mandate missing required amount field: #{field}",
            hint: "#{field} is a required AP2 mandate field",
          )
        end

        return if value.is_a?(Integer) && value.positive?

        raise Errors::Forbidden.new(
          "mandate #{field} must be a positive integer number of cents",
          hint: "#{field} was #{value.inspect}",
        )
      end

      # §11.2: at least one entry; the settlement is reconciled from it.
      def require_line_items!(payload)
        value = payload[:line_items]
        if value.nil?
          raise Errors::Forbidden.new(
            "mandate missing required line_items field",
            hint: "line_items is a required AP2 cart-mandate field — the settlement trail " \
                  "is reconciled from it",
          )
        end

        unless value.is_a?(Array)
          raise Errors::Forbidden.new(
            "mandate line_items must be an array",
            hint: "line_items was #{value.class}",
          )
        end

        return unless value.empty?

        raise Errors::Forbidden.new(
          "mandate line_items must not be empty",
          hint: "a cart mandate says WHAT is being bought and the settlement is reconciled " \
                "from it — an empty array withholds both while a positive total is charged",
        )
      end

      # §11.1: refuses a non-String, blank or non-alpha-3 currency and returns
      # the canonical form, so the spending-cap tally has one key per currency.
      def require_currency!(payload)
        value = payload[:currency]
        if value.nil?
          raise Errors::Forbidden.new(
            "mandate missing required currency field",
            hint: "currency is a required AP2 mandate field",
          )
        end

        unless value.is_a?(String) && !value.strip.empty?
          raise Errors::Forbidden.new(
            "mandate currency must be a non-empty string",
            hint: "currency was #{value.inspect} — send the currency code this mandate is " \
                  "denominated in (spec §11.1: an ISO 4217 alpha-3 code)",
          )
        end

        code = canonical_currency(value)
        return code if CURRENCY_CODE.match?(code)

        raise Errors::Forbidden.new(
          "mandate currency is not an ISO 4217 alpha-3 code",
          hint: "currency was #{value.inspect} — send the three-letter code, not a name or a " \
                "number (spec §11.1: `\"eur\"`, `\"usd\"`; `\"Euro\"`, `\"US\"` and `\"978\"` are refused)",
        )
      end

      # Public: an operator reading `settlements.currency` needs the same fold.
      def canonical_currency(value)
        value.to_s.strip.downcase
      end

      # Before `Time.at`, which raises on a String.
      def require_numeric_timestamp!(payload, field)
        return if payload[field].is_a?(Numeric)

        raise Errors::BadRequest.new(
          "mandate #{field} must be an integer Unix timestamp",
          hint: "#{field} was #{payload[field].class} — send #{field} as a NumericDate integer",
        )
      end

      # Longer than this counts as non-expiring, which the spec refuses.
      MAX_MANDATE_LIFETIME_SECONDS = 24 * 60 * 60

      # exp − now, not exp − iat, so a future-dated iat cannot stretch it.
      def enforce_max_lifetime!(payload)
        return if payload[:exp].to_i - Time.now.to_i <= MAX_MANDATE_LIFETIME_SECONDS

        raise Errors::BadRequest.new(
          "mandate lifetime exceeds the maximum of #{MAX_MANDATE_LIFETIME_SECONDS}s",
          hint: "exp must be at most #{MAX_MANDATE_LIFETIME_SECONDS}s in the future; " \
                "a non-expiring mandate is rejected",
        )
      end
      private_class_method :require_amount!, :require_numeric_timestamp!, :enforce_max_lifetime!

      REQUIRED_CLAIMS = %w[id user_id agent_id iss iat exp].freeze

      def decode_and_check(raw_jws, identity)
        key    = AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(identity.agent_id)
        issuer = Kiosk.current_issuer
        payload, = ::JWT.decode(raw_jws, key, true, algorithms: ["RS256"], required_claims: REQUIRED_CLAIMS)
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != issuer
          raise Errors::Forbidden.new("mandate issuer mismatch", hint: "expected #{issuer.inspect}")
        end
        # As strings: a bigint-PK host's identity carries an Integer.
        unless payload[:agent_id].to_s == identity.agent_id.to_s &&
               payload[:user_id].to_s == identity.user_id.to_s
          raise Errors::Forbidden.new(
            "mandate principal mismatch",
            hint: "mandate must be signed for the authenticated agent/user",
          )
        end

        require_numeric_timestamp!(payload, :iat)
        require_numeric_timestamp!(payload, :exp)
        enforce_max_lifetime!(payload)

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("mandate expired")
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Forbidden.new(
          "mandate missing a required claim",
          hint: "a mandate carries #{REQUIRED_CLAIMS.join(", ")}",
        )
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new(
          "mandate signature invalid",
          hint: "a mandate is a compact RS256 JWS signed with the agent's payment key",
        )
      rescue Kiosk::AgentIdentityProviders::InvalidToken
        # The agent was revoked between authentication and now.
        raise Errors::Forbidden.new(
          "mandate agent has no registered payment key",
          hint: "the authenticated agent is revoked or unknown",
        )
      end
      private_class_method :decode_and_check
    end
  end
end
