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

          cus = @stripe.customers.create({ name: "principal-#{user_id}" })
          @customer_saver.call(user_id, cus.id)
          cus.id
        end

        # nil when none is mapped or Stripe no longer has the mapped one.
        def live_customer(user_id)
          cus_id = @customer_resolver.call(user_id)
          return nil unless cus_id

          customer = @stripe.customers.retrieve(cus_id)
          customer unless customer.respond_to?(:deleted) && customer.deleted
        rescue ::Stripe::InvalidRequestError => e
          raise unless e.code == 'resource_missing'
        end

        # `[customer_id, card_id]` for the newest card on the mapped Customer, or
        # nil. One Stripe call: a deleted Customer keeps no card, and a Customer
        # Stripe does not know is no card.
        def saved_card(user_id)
          cus_id = @customer_resolver.call(user_id)
          return nil unless cus_id

          card = @stripe.payment_methods.list(customer: cus_id, type: 'card', limit: 1).data.first
          [cus_id, card.id] if card
        rescue ::Stripe::InvalidRequestError => e
          raise unless e.code == 'resource_missing'
        end
      end
    end
  end
end
