# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A consistent mandate pair in a currency the operator does not price in
      # must be refused by the operator at capture.
      class WrongCurrencyCart < Scenario
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

          a     = client.register!
          owned = profile.create_owned.call(client, a)
          m     = profile.pay_for.call(client, a, owned)
          m[:intent] = m[:intent].merge(currency: foreign)
          m[:cart]   = m[:cart].merge(currency: foreign)
          resp = client.pay(a, intent: m[:intent], cart: m[:cart])
          # A 401 would mean the cart never reached the operator's capture check.
          verdict_from(resp,
                       expect: 403,
                       detail: "a #{foreign} cart settled at a #{native.upcase} operator " \
                               "(HTTP #{resp.status})")
        end
      end
    end
  end
end
