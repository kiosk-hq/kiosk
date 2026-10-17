# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # Maps a principal to its Stripe Customer and the Customer's saved card.
      module Customers
        private

        def ensure_customer(user_id)
          existing = live_customer(user_id)
          return existing.id if existing

          cus = ::Stripe::Customer.create({ name: "principal-#{user_id}" })
          @customer_saver.call(user_id, cus.id)
          cus.id
        end

        # nil when none is mapped or Stripe no longer has the mapped one.
        def live_customer(user_id)
          cus_id = @customer_resolver.call(user_id)
          return nil unless cus_id

          customer = ::Stripe::Customer.retrieve(cus_id)
          customer unless customer.respond_to?(:deleted) && customer.deleted
        rescue ::Stripe::InvalidRequestError => e
          raise unless e.code == 'resource_missing'
        end

        def saved_payment_method_for(customer)
          customer.invoice_settings&.default_payment_method ||
            ::Stripe::PaymentMethod.list(customer: customer.id, type: 'card').data.first&.id
        end
      end
    end
  end
end
