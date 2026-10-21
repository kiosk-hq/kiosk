# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A payment mandate in a currency other than the checkout's, with the
      # same amount, must be refused before any capture.
      class WrongCurrencyPayment < Scenario
        ALTERNATIVES = %w[usd eur gbp jpy].freeze

        def initialize
          super(name: 'WrongCurrencyPayment')
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
          checkout_jwt = profile.pay_for.call(client, a, profile.create_owned.call(client, a))
          amount = JWT.decode(checkout_jwt, nil, false).first['total_amount_cents']
          resp = client.pay_raw(a, **mandates_with_payment(a, checkout_jwt, payment_amount: { amount:, currency: foreign }))
          # A 401 would mean the payment never reached the mandate check.
          verdict_from(resp, expect: 403,
                             detail: "a #{foreign} payment of a #{native.upcase} checkout settled " \
                                     "(HTTP #{resp.status})")
        end
      end
    end
  end
end
