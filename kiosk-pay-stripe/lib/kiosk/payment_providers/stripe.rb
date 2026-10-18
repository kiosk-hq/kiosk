# frozen_string_literal: true

require 'kiosk'
require 'kiosk/payment_providers/stripe/version'
require 'kiosk/payment_providers/stripe/charges'
require 'kiosk/payment_providers/stripe/customers'
require 'kiosk/payment_providers/stripe/setup_sessions'

module Kiosk
  module PaymentProviders
    # Stripe PSP adapter: the human saves a card once on the operator's Stripe
    # account, and purchases are charged `off_session`.
    # Always reference the SDK as `::Stripe` — bare `Stripe` is this class.
    class Stripe < Base
      include Charges
      include Customers
      include SetupSessions

      VERSION = StripeVersion::VERSION

      # Open Checkout Sessions the reuse lookup asks for. A full page with no
      # match is logged: the reusable session may have been truncated away.
      SETUP_SESSION_LIST_LIMIT = 10

      # Stripe substitutes the session id on the redirect.
      RETURN_QUERY = 'session_id={CHECKOUT_SESSION_ID}'

      PAID        = 'succeeded'
      # Terminal PaymentIntent states in which no money moved.
      NOT_CHARGED = %w[canceled requires_payment_method].freeze

      # @param customer_resolver [#call] `(user_id) -> customer_id | nil`; {CustomerRecord.resolve} when omitted
      # @param customer_saver [#call] `(user_id, customer_id)`; {CustomerRecord.save} when omitted
      # @param api_base [String, nil] the Stripe API URL, e.g. a local stripe-mock; Stripe's own when nil
      def initialize(api_key:, customer_resolver: nil, customer_saver: nil, api_base: nil)
        super()
        @customer_resolver = customer_resolver || customer_record_method(:resolve)
        @customer_saver    = customer_saver || customer_record_method(:save)
        require 'stripe'
        # This adapter's own client: the key and the URL are not process-global.
        @stripe = ::Stripe::StripeClient.new(api_key, api_base:).v1
      end

      # A hosted Checkout page in `mode: "setup"`. An open setup session for the
      # same return target is reused, so an assistant polling `payment_setup`
      # keeps handing its human the same link. The SetupIntent the page creates
      # takes Stripe's default `usage`, `off_session`, so `pay` can charge the card.
      def setup_url(user_id:, return_url:)
        success_url = "#{return_url}?#{RETURN_QUERY}"
        cus_id      = ensure_customer(user_id)

        outstanding_setup_session(cus_id, success_url: success_url)&.url ||
          @stripe.checkout.sessions.create(
            mode: 'setup',
            customer: cus_id,
            client_reference_id: user_id,
            payment_method_types: ['card'],
            success_url: success_url
          ).url
      end

      # The principal the returning browser's Checkout Session was minted for.
      def setup_return_user_id(params)
        session_id = params['session_id'].to_s
        return nil if session_id.empty?

        @stripe.checkout.sessions.retrieve(session_id).client_reference_id
      end

      def setup_required?(user_id:) = !saved_method?(user_id: user_id)

      def saved_method?(user_id:) = !saved_card(user_id).nil?

      # Charges the principal's saved card off_session; the mandate's payment method is not used.
      def capture(cart_mandate, **)
        customer_id, payment_method = saved_card(cart_mandate.user_id)
        raise SetupRequired unless payment_method

        intent = charge(cart_mandate, customer_id, payment_method)
        ensure_paid!(intent)
        {
          psp_reference: intent.id,
          settled_amount_cents: intent.amount_received,
          settled_at: Time.at(intent.created).utc
        }
      end

      def refund(psp_reference:, amount_cents:, key:)
        refund = @stripe.refunds.create(
          { payment_intent: psp_reference, amount: amount_cents },
          { idempotency_key: "#{psp_reference}-refund-#{key}" }
        )
        { psp_reference: refund.id, refunded_psp_reference: psp_reference,
          refunded_amount_cents: amount_cents, refunded_at: Time.at(refund.created).utc }
      rescue ::Stripe::StripeError
        raise PaymentFailed, 'the payment processor did not refund the charge'
      end

      private

      def customer_record_method(name)
        require 'kiosk/payment_providers/stripe/customer_record'
        CustomerRecord.method(name)
      end
    end
  end
end
