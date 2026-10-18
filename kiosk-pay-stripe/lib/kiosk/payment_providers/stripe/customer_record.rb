# frozen_string_literal: true

require 'active_record'

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # The principal → Stripe Customer mapping, one row per principal, in the
      # host's `stripe_customers` table (`bin/rails g kiosk:pay_stripe:install`).
      # The adapter's default resolver and saver.
      class CustomerRecord < ::ActiveRecord::Base
        self.table_name = 'stripe_customers'

        def self.resolve(user_id) = find_by(user_id: user_id)&.customer_id

        def self.save(user_id, customer_id)
          find_or_initialize_by(user_id: user_id).update!(customer_id: customer_id)
        end
      end
    end
  end
end
