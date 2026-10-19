# frozen_string_literal: true

require 'jwt'

module Kiosk
  module Server
    # Verifies the agent-signed AP2 mandate chain (intent → cart → payment):
    # signed by the authenticated agent's key, issued for this origin, bound to
    # the authenticated principal, and within the intent's cap.
    module MandateVerifier
      # §11.1: an ISO 4217 alpha-3 code, matched after {canonical_currency}.
      CURRENCY_CODE = /\A[a-z]{3}\z/

      REQUIRED_CLAIMS = %w[id user_id agent_id iss iat exp].freeze

      # Longer than this counts as non-expiring, which the spec refuses.
      MAX_MANDATE_LIFETIME_SECONDS = 24 * 60 * 60

      module_function

      def verify_intent(raw_jws:, identity:)
        payload = Token.decode_and_check(raw_jws, identity)
        require_amount!(payload, :cap_amount_cents)
        currency = require_currency!(payload)

        Kiosk::Mandate::IntentMandate.new(
          **Token.common(payload, raw_jws),
          scope: payload[:scope], cap_amount_cents: payload[:cap_amount_cents], currency: currency
        )
      end

      # `payment_method` is optional: the PSP charges the principal's card on file.
      def verify_payment(raw_jws:, identity:, cart:)
        payload = Token.decode_and_check(raw_jws, identity)
        require_amount!(payload, :amount_cents)
        currency = require_currency!(payload)
        Binding.payment_to_cart!(payload, currency, cart)

        Kiosk::Mandate::PaymentMandate.new(
          **Token.common(payload, raw_jws),
          cart_mandate_id: payload[:cart_mandate_id], payment_method: payload[:payment_method],
          amount_cents: payload[:amount_cents], currency: currency
        )
      end

      def verify_cart(raw_jws:, identity:, intent:)
        payload = Token.decode_and_check(raw_jws, identity)
        require_amount!(payload, :total_amount_cents)
        currency = require_currency!(payload)
        require_line_items!(payload)

        fields = Token.claims(payload, :intent_mandate_id, :line_items, :total_amount_cents)
        cart = Kiosk::Mandate::CartMandate.new(**Token.common(payload, raw_jws), **fields, currency: currency)
        Binding.cart_to_intent!(cart, intent)
        cart
      end

      # Before any `.to_i`: nil, zero or negative would launder the cap.
      def require_amount!(payload, field)
        value = payload[field]
        raise Errors::Forbidden.new("mandate missing required amount field: #{field}", hint: "#{field} is a required AP2 mandate field") if value.nil?
        return if value.is_a?(Integer) && value.positive?

        raise Errors::Forbidden.new(
          "mandate #{field} must be a positive integer number of cents",
          hint: "#{field} was #{value.inspect}"
        )
      end

      # §11.2: at least one entry; the settlement is reconciled from it.
      def require_line_items!(payload)
        value = payload[:line_items]
        raise Errors::Forbidden.new('mandate missing required line_items field', hint: LINE_ITEMS_HINT) if value.nil?
        raise Errors::Forbidden.new('mandate line_items must be an array', hint: "line_items was #{value.class}") unless value.is_a?(Array)
        return unless value.empty?

        raise Errors::Forbidden.new(
          'mandate line_items must not be empty',
          hint: 'a cart mandate says WHAT is being bought and the settlement is reconciled ' \
                'from it — an empty array withholds both while a positive total is charged'
        )
      end

      LINE_ITEMS_HINT = 'line_items is a required AP2 cart-mandate field — the settlement trail ' \
                        'is reconciled from it'

      # §11.1: refuses a non-String, blank or non-alpha-3 currency and returns
      # the canonical form, so the spending-cap tally has one key per currency.
      def require_currency!(payload)
        value = payload[:currency]
        raise Errors::Forbidden.new('mandate missing required currency field', hint: 'currency is a required AP2 mandate field') if value.nil?
        raise Errors::Forbidden.new('mandate currency must be a non-empty string', hint: blank_currency_hint(value)) unless value.is_a?(String) && !value.strip.empty?

        code = canonical_currency(value)
        return code if CURRENCY_CODE.match?(code)

        raise Errors::Forbidden.new(
          'mandate currency is not an ISO 4217 alpha-3 code',
          hint: "currency was #{value.inspect} — send a three-letter currency code, such as \"eur\""
        )
      end

      def blank_currency_hint(value)
        "currency was #{value.inspect} — send the three-letter currency code of this mandate, such as \"eur\""
      end

      # Public: an operator reading `settlements.currency` needs the same lower-casing.
      def canonical_currency(value)
        value.to_s.downcase
      end
      private_class_method :require_amount!, :blank_currency_hint

      # How each mandate in the chain must agree with the one it follows.
      module Binding
        module_function

        def payment_to_cart!(payload, currency, cart)
          raise Errors::Forbidden, 'payment not bound to the cart' unless payload[:cart_mandate_id] == cart.id
          return if payload[:amount_cents].to_i == cart.total_amount_cents.to_i && currency == cart.currency

          raise Errors::Forbidden, 'payment amount/currency does not match cart'
        end

        def cart_to_intent!(cart, intent)
          unless cart.intent_mandate_id == intent.id
            raise Errors::Forbidden.new('cart not bound to the intent',
                                        hint: "expected intent_mandate_id #{intent.id.inspect}")
          end
          cart_currency!(cart, intent)
          cart_cap!(cart, intent)
        end

        # A cap is meaningless across currencies.
        def cart_currency!(cart, intent)
          return if cart.currency == intent.currency

          raise Errors::Forbidden.new('cart currency does not match intent cap currency',
                                      hint: "cart #{cart.currency.inspect} != intent #{intent.currency.inspect}")
        end

        def cart_cap!(cart, intent)
          return unless cart.total_amount_cents.to_i > intent.cap_amount_cents.to_i

          raise Errors::Forbidden.new('cart total exceeds intent cap',
                                      hint: "cart #{cart.total_amount_cents} > cap #{intent.cap_amount_cents}")
        end
      end

      # The signed JWS: its signature, issuer, principal and lifetime.
      module Token
        module_function

        # The attributes every mandate carries.
        def common(payload, raw_jws)
          { id: payload[:id], user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
            expires_at: Time.at(payload[:exp]).utc, created_at: Time.at(payload[:iat]).utc, raw_jws: raw_jws }
        end

        # The named claims, nil when absent.
        def claims(payload, *names) = names.index_with { |name| payload[name] }

        def decode_and_check(raw_jws, identity)
          payload = decode(raw_jws, identity)
          check_principal!(payload, identity)
          require_numeric_timestamp!(payload, :iat)
          require_numeric_timestamp!(payload, :exp)
          enforce_max_lifetime!(payload)
          payload
        end

        def decode(raw_jws, identity)
          payload, = ::JWT.decode(raw_jws, payment_key(identity), true, algorithms: ['RS256'], required_claims: REQUIRED_CLAIMS)
          payload.transform_keys(&:to_sym)
        rescue ::JWT::ExpiredSignature
          raise Errors::Forbidden, 'mandate expired'
        rescue ::JWT::MissingRequiredClaim
          raise Errors::Forbidden.new('mandate missing a required claim', hint: "a mandate carries #{REQUIRED_CLAIMS.join(', ')}")
        rescue ::JWT::DecodeError
          raise Errors::Forbidden.new('mandate signature invalid', hint: "a mandate is a compact RS256 JWS signed with the agent's payment key")
        end

        def payment_key(identity)
          AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(identity.agent_id)
        rescue Kiosk::AgentIdentityProviders::InvalidToken
          # The agent was revoked between authentication and now.
          raise Errors::Forbidden.new('mandate agent has no registered payment key', hint: 'the authenticated agent is revoked or unknown')
        end

        def check_principal!(payload, identity)
          issuer = Kiosk.current_issuer
          raise Errors::Forbidden.new('mandate issuer mismatch', hint: "expected #{issuer.inspect}") if payload[:iss] != issuer
          # As strings: a bigint-PK host's identity carries an Integer.
          return if payload[:agent_id].to_s == identity.agent_id.to_s && payload[:user_id].to_s == identity.user_id.to_s

          raise Errors::Forbidden.new('mandate principal mismatch', hint: 'mandate must be signed for the authenticated agent/user')
        end

        # Before `Time.at`, which raises on a String.
        def require_numeric_timestamp!(payload, field)
          return if payload[field].is_a?(Numeric)

          raise Errors::BadRequest.new(
            "mandate #{field} must be an integer Unix timestamp",
            hint: "#{field} was #{payload[field].class} — send #{field} as a NumericDate integer"
          )
        end

        # exp − now, not exp − iat, so a future-dated iat cannot stretch it.
        def enforce_max_lifetime!(payload)
          return if payload[:exp].to_i - Time.now.to_i <= MAX_MANDATE_LIFETIME_SECONDS

          raise Errors::BadRequest.new(
            "mandate lifetime exceeds the maximum of #{MAX_MANDATE_LIFETIME_SECONDS}s",
            hint: "exp must be at most #{MAX_MANDATE_LIFETIME_SECONDS}s in the future; " \
                  'a non-expiring mandate is rejected'
          )
        end
      end
    end
  end
end
