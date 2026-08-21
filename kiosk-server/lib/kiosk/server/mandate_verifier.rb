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
        # `cap_amount_cents` is a REQUIRED intent field (spec AP2 table). ABSENT
        # would nil-coerce to 0 in the verify_cart cap comparison, making that
        # comparison vacuous; reject it here, before any .to_i.
        require_amount!(payload, :cap_amount_cents)
        require_currency!(payload)

        Kiosk::Mandate::IntentMandate.new(
          id: payload[:id], user_id: payload[:user_id], agent_id: payload[:agent_id],
          issuer: payload[:iss], scope: payload[:scope],
          cap_amount_cents: payload[:cap_amount_cents], currency: payload[:currency],
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
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
        # `amount_cents` is a REQUIRED payment field (spec AP2 table). ABSENT
        # would nil-coerce to 0 below, so a payment omitting it would "match" a
        # 0-cent cart and persist a 0-cent row; reject before any .to_i.
        require_amount!(payload, :amount_cents)
        require_currency!(payload)

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
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
          raw_jws: raw_jws,
        )
      end

      # Verify a CartMandate JWS → {Kiosk::Mandate::CartMandate}, enforcing
      # that it is bound to `intent` and stays within the intent's cap.
      def verify_cart(raw_jws:, identity:, intent:)
        payload = decode_and_check(raw_jws, identity)
        # `total_amount_cents` is a REQUIRED cart field (spec AP2 table). ABSENT
        # would nil-coerce to 0 in the cap comparison below (0 <= any cap) and
        # in verify_payment's amount match, making both vacuous and persisting a
        # 0-cent cart row; reject before any .to_i.
        require_amount!(payload, :total_amount_cents)
        require_currency!(payload)
        require_line_items!(payload)

        cart = Kiosk::Mandate::CartMandate.new(
          id: payload[:id], intent_mandate_id: payload[:intent_mandate_id],
          user_id: payload[:user_id], agent_id: payload[:agent_id], issuer: payload[:iss],
          line_items: payload[:line_items], total_amount_cents: payload[:total_amount_cents],
          currency: payload[:currency],
          expires_at: Time.at(payload[:exp]),
          created_at: Time.at(payload[:iat]),
          raw_jws: raw_jws,
        )

        unless cart.intent_mandate_id == intent.id
          raise Errors::Forbidden.new("cart not bound to the intent",
                                      hint: "expected intent_mandate_id #{intent.id.inspect}")
        end
        # Currency guard: the cap comparison is meaningless across
        # currencies — 4999 "USD" is NOT within a 5000 "EUR" cap. verify_payment
        # already checks amount AND currency together; the intent→cart cap must
        # do the same, or an agent could bypass a EUR cap by pricing the cart in
        # a weaker unit. Reject the mismatch before comparing the amounts.
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

      # Reject a REQUIRED amount field that is ABSENT (nil) or NON-POSITIVE,
      # BEFORE any `.to_i` coercion. `nil.to_i` is 0, so an omitted amount would
      # otherwise satisfy the spending-envelope checks vacuously (0 <= cap,
      # 0 == 0) and persist a 0-cent row.
      #
      # K-543: a NEGATIVE amount launders the spending cap. A negative cart total
      # passes the cap comparison (−100000 <= 5000), matches a negative payment,
      # settles on any PSP that echoes the amount, and drives the settlements SUM
      # negative — permanently RAISING this agent's effective cap by that amount.
      # Zero is equally meaningless. Every mandate amount is a positive integer
      # number of cents; reject anything else here, before the envelope checks.
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

      # Reject a cart whose `line_items` are ABSENT or are not an array (K-741).
      #
      # `line_items` was OPTIONAL until Phil's `LINE-ITEMS-REQUIRED` decision
      # (2026-08-16, answering P6 of the third-party review). The reason it
      # could not stay optional is that the settlement and reconciliation path
      # READS it and has no fallback: the demos' `my_orders` join and the
      # `line_items @> …::jsonb` replace-guard (K-544, which the K-545 pay-race
      # fix stands on) both look inside it. An assistant that omitted it could
      # legally pay and leave the operator holding a settlement it cannot match
      # to any domain object — degraded audit and reconciliation with no error
      # raised anywhere, which is the worst shape a money path can have.
      #
      # The alternative the review offered — leave it optional and tell
      # operators whose reconciliation depends on it to reject the omission
      # themselves — was explicitly DECLINED: it makes every operator
      # re-implement the same guard and makes the wire mean different things at
      # different origins.
      #
      # `Errors::Forbidden`, not `BadRequest`, because that is what every other
      # missing REQUIRED mandate field answers here (`require_amount!`,
      # `require_currency!`) — a mandate that does not carry what a mandate must
      # carry is not authorisation, and the assistant learns the same way for
      # all of them.
      #
      # An EMPTY array does NOT conform (K-857, settling what K-741 left open).
      # `[]` is present, so it satisfies both the schema's `required` and the
      # nil-check below, while carrying exactly as much reconciliation value as
      # omission did — which is the whole defect K-741 was filed against. §11.2
      # now says so normatively ("MUST carry at least one entry") and
      # `mandates.schema.json` states `minItems: 1`; this is the same
      # constraint at the verifier, so the two refuse the same set.
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

      # Reject an ABSENT (nil) required `currency`. With both intent and cart
      # omitting it, the cap guard (`nil != nil` → false) and the
      # verify_payment match (`nil == nil` → true) both pass vacuously, then the
      # NOT NULL currency column 500s after partial persist (same class as the missing-amount case).
      def require_currency!(payload)
        return unless payload[:currency].nil?

        raise Errors::Forbidden.new(
          "mandate missing required currency field",
          hint: "currency is a required AP2 mandate field",
        )
      end

      # Reject a timestamp claim that is not a number (Integer/Float NumericDate),
      # BEFORE it reaches `Time.at` — `Time.at("...")` raises TypeError → 500.
      def require_numeric_timestamp!(payload, field)
        return if payload[field].is_a?(Numeric)

        raise Errors::BadRequest.new(
          "mandate #{field} must be an integer Unix timestamp",
          hint: "#{field} was #{payload[field].class} — send #{field} as a NumericDate integer",
        )
      end

      # A mandate authorises a single near-term transaction. Anything longer is
      # treated as effectively non-expiring, which the spec says MUST be
      # rejected. 24 h leaves generous headroom over the ~10 min the flows use.
      MAX_MANDATE_LIFETIME_SECONDS = 24 * 60 * 60

      # Reject a mandate whose remaining lifetime (exp − now) exceeds the maximum.
      # Uses exp − now, not exp − iat, so a future-dated iat cannot be used to
      # sneak an effectively non-expiring exp past the cap.
      def enforce_max_lifetime!(payload)
        return if payload[:exp].to_i - Time.now.to_i <= MAX_MANDATE_LIFETIME_SECONDS

        raise Errors::BadRequest.new(
          "mandate lifetime exceeds the maximum of #{MAX_MANDATE_LIFETIME_SECONDS}s",
          hint: "exp must be at most #{MAX_MANDATE_LIFETIME_SECONDS}s in the future; " \
                "a non-expiring mandate is rejected",
        )
      end
      private_class_method :require_amount!, :require_numeric_timestamp!, :enforce_max_lifetime!

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
        # Compare the principal as STRING on BOTH sides. The agent
        # signs the mandate's `user_id`/`agent_id` with whatever the register
        # response returned (a String — AgentRegistration stringifies user_id),
        # but on a bigint-PK host the authenticated {Kiosk::Identity} carries
        # the raw Integer that the token's `sub` round-trips as. A strict `==`
        # ("42" == 42) is always false, so every mandate on a bigint host was
        # wrongly Forbidden. Normalising to string keeps uuid hosts unchanged.
        unless payload[:agent_id].to_s == identity.agent_id.to_s &&
               payload[:user_id].to_s == identity.user_id.to_s
          raise Errors::Forbidden.new(
            "mandate principal mismatch",
            hint: "mandate must be signed for the authenticated agent/user",
          )
        end

        # K-551: `iat`/`exp` reach `Time.at` in the mandate constructors. A
        # numeric-STRING exp slips past JWT's decode-time expiry check (it
        # coerces via to_i) and a string iat is not checked by JWT at all, so
        # both would raise `TypeError` in `Time.at(String)` as an HTTP 500.
        # Validate the type here → a clean 400, before any Time.at.
        require_numeric_timestamp!(payload, :iat)
        require_numeric_timestamp!(payload, :exp)
        # K-551: JWT rejects an EXPIRED mandate but not an effectively
        # non-expiring one (exp in the year 3000). The spec says a non-expiring
        # mandate MUST be rejected — cap the lifetime.
        enforce_max_lifetime!(payload)

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("mandate expired")
      rescue ::JWT::MissingRequiredClaim => e
        raise Errors::Forbidden.new("mandate missing required claim: #{e.message}")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("mandate signature invalid: #{e.message}")
      rescue Kiosk::AgentIdentityProviders::InvalidToken
        # agent_payment_key raises this when the authenticated agent_id has no
        # live kiosk.agents row (revoked or deleted between auth and now). It is
        # NOT an Errors::Base, so it escaped these rescues and the controller's
        # Errors::Base rescue as an HTTP 500 (same 500-not-4xx class as the
        # other guarded paths, whose guard only covered the nil-agent_id sibling).
        # A revoked/absent agent has no signing key → clean 403 Forbidden.
        raise Errors::Forbidden.new(
          "mandate agent has no registered payment key",
          hint: "the authenticated agent is revoked or unknown",
        )
      end
      private_class_method :decode_and_check
    end
  end
end
