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
            name: 'WrongCurrencyCart',
            category: 'payment',
            description: 'A chain-consistent cart denominated in a currency the operator does not ' \
                         'price in must be rejected at capture',
          )
        end

        def call(client, profile)
          native = profile.currency.to_s.downcase
          return skip_verdict('no currency') if native.empty?

          skip_unless(profile, create_owned: 'no create_owned', pay_for: 'no pay_for') ||
            attack(client, profile, native)
        end

        private

        def attack(client, profile, native)
          foreign = ALTERNATIVES.find { |c| c != native }
          a = client.register!
          mandates = profile.pay_for.call(client, a, profile.create_owned.call(client, a))
          resp = client.pay(a, intent: mandates[:intent].merge(currency: foreign),
                               cart: mandates[:cart].merge(currency: foreign))
          # A 401 would mean the cart never reached the operator's capture check.
          verdict_from(resp, expect: 403,
                             detail: "a #{foreign} cart settled at a #{native.upcase} operator " \
                                     "(HTTP #{resp.status})")
        end
      end
    end
  end
end
