# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A chain-consistent mandate pair denominated in a currency the operator
      # does not price in must not settle.
      #
      # This is a CASHIER check rather than an authorization one, and the
      # distinction is the whole point of the scenario. `kiosk-server` verifies
      # that the intent, the cart and the payment agree with each other; it has
      # no opinion about what those agreeing numbers MEAN, because the catalogue
      # is the operator's. So a cart whose every link says `usd` is internally
      # perfect and still has to be refused — by the operator, at capture — or a
      # caller sets the unit of account and the operator ships goods for
      # whatever the weakest currency it names is worth.
      #
      # Requires {Profile#currency}, {Profile#create_owned} and
      # {Profile#pay_for}; skips when any of the three is absent.
      class WrongCurrencyCart < Scenario
        # The probe's currency is one the operator does NOT price in, picked
        # from a short list rather than hard-coded, so an operator that prices
        # in dollars is probed with euros instead of being probed with its own
        # currency and printing BLOCKED for a cart that was never foreign.
        ALTERNATIVES = %w[usd eur gbp jpy].freeze

        def initialize
          super(
            name:        "WrongCurrencyCart",
            category:    "payment",
            description: "A chain-consistent cart denominated in a currency the operator does not " \
                         "price in must be rejected at capture",
          )
        end

        def call(client, profile)
          native = profile.currency.to_s.downcase
          return skip_verdict("no currency") if native.empty?
          return skip_verdict("no create_owned") unless profile.create_owned
          return skip_verdict("no pay_for") unless profile.pay_for

          foreign = ALTERNATIVES.find { |c| c != native }

          a     = register_principal(client, name: "redteam-cur-a", profile:)
          owned = profile.create_owned.call(client, a)
          m     = profile.pay_for.call(client, a, owned)
          m[:intent] = m[:intent].merge(currency: foreign)
          m[:cart]   = m[:cart].merge(currency: foreign)
          resp = client.pay(a, intent: m[:intent], cart: m[:cart])
          verdict_from(resp,
                       detail: "a #{foreign} cart settled at a #{native.upcase} operator " \
                               "(HTTP #{resp.status})")
        end
      end
    end
  end
end
