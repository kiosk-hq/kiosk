# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # Maps a principal to its Stripe Customer and the Customer's saved card.
      module Customers
        # TEST-ONLY: saves a test card as the Customer's default, as the hosted page would.
        def attach_test_card(user_id:, payment_method: 'pm_card_visa')
          cus_id = ensure_customer(user_id)
          setup = ::Stripe::SetupIntent.create(
            { customer: cus_id, payment_method: payment_method, payment_method_types: ['card'],
              confirm: true, usage: 'off_session' }
          )
          ::Stripe::Customer.update(cus_id, { invoice_settings: { default_payment_method: setup.payment_method } })
          cus_id
        end

        private

        # The Customer and its saved card. With test_autocard, a missing card is attached first.
        def customer_and_payment_method(user_id)
          customer = live_customer(user_id)
          pm = customer && saved_payment_method_for(customer)
          if pm.nil? && @test_autocard
            customer = ::Stripe::Customer.retrieve(attach_test_card(user_id: user_id))
            pm = saved_payment_method_for(customer)
          end
          [customer, pm]
        end

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
