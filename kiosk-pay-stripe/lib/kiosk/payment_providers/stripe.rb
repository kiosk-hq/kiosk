# frozen_string_literal: true

require "kiosk"
require "kiosk/payment_providers/stripe/version"

module Kiosk
  module PaymentProviders
    # Stripe PSP adapter. The human saves a card once, on the operator's Stripe
    # account, as a Customer + PaymentMethod; purchases are then charged
    # `off_session`. The principal→Customer mapping is the host's, injected as
    # `customer_resolver:` and `customer_saver:` callables.
    #
    # Always reference the SDK as `::Stripe` — bare `Stripe` is this class.
    class Stripe < Base
      VERSION = StripeVersion::VERSION

      # Open Checkout Sessions the reuse lookup asks for. A full page with no
      # match is logged: the reusable session may have been truncated away.
      SETUP_SESSION_LIST_LIMIT = 10

      # Stripe substitutes the session id on the redirect.
      RETURN_QUERY = "session_id={CHECKOUT_SESSION_ID}"

      # @param api_key [String] Stripe secret key
      # @param customer_resolver [#call] `(user_id) -> customer_id | nil`
      # @param customer_saver [#call] `(user_id, customer_id)`; replaces any
      #   earlier mapping for that user
      # @param test_autocard [Boolean] TEST-ONLY: attach a test card at capture
      #   instead of requiring the hosted card entry
      def initialize(customer_resolver:, customer_saver:, api_key: nil, test_autocard: false)
        super()
        @api_key           = api_key || ENV.fetch("STRIPE_SECRET_KEY", nil)
        @customer_resolver = customer_resolver
        @customer_saver    = customer_saver
        @test_autocard     = test_autocard
        require "stripe"
        # Process-global: one adapter per process.
        ::Stripe.api_key = @api_key
      end

      # A hosted Checkout page in `mode: "setup"`. An open setup session for the
      # same return target is reused, so an assistant polling `payment_setup`
      # keeps handing its human the same link.
      #
      # @return [String] hosted Stripe Checkout URL
      def setup_url(user_id:, return_url:)
        success_url = "#{return_url}?#{RETURN_QUERY}"
        cus_id      = ensure_customer(user_id)

        outstanding_setup_session(cus_id, success_url: success_url)&.url ||
          ::Stripe::Checkout::Session.create(
            mode:                 "setup",
            customer:             cus_id,
            client_reference_id:  user_id,
            payment_method_types: ["card"],
            success_url:          success_url,
          ).url
      end

      # The principal the returning browser's Checkout Session was minted for,
      # as Stripe answers it.
      #
      # @return [String, nil]
      def setup_return_user_id(params)
        session_id = params["session_id"].to_s
        return nil if session_id.empty?

        ::Stripe::Checkout::Session.retrieve(session_id).client_reference_id
      end

      # True when the principal must save a card before a charge. Never true
      # under `test_autocard`.
      def setup_required?(user_id:)
        return false if @test_autocard

        !saved_method?(user_id: user_id)
      end

      # True when the principal's Customer has a usable saved card.
      def saved_method?(user_id:)
        customer = live_customer(user_id)
        !customer.nil? && !saved_payment_method_for(customer).nil?
      end

      # Charges the principal's saved card off_session; the mandate's payment
      # method is not used.
      #
      # @return [Hash] { psp_reference:, settled_amount_cents:, settled_at: }
      # @raise [SetupRequired] when there is no card to charge
      # @raise [PaymentFailed] when Stripe declines or cannot confirm the charge
      def capture(cart_mandate, payment_method: nil)
        customer = live_customer(cart_mandate.user_id)
        pm = customer && saved_payment_method_for(customer)
        if pm.nil? && @test_autocard
          customer = ::Stripe::Customer.retrieve(attach_test_card(user_id: cart_mandate.user_id))
          pm = saved_payment_method_for(customer)
        end
        raise SetupRequired unless pm

        intent =
          begin
            ::Stripe::PaymentIntent.create(
              {
                amount:         cart_mandate.total_amount_cents,
                currency:       cart_mandate.currency,
                customer:       customer.id,
                payment_method: pm,
                off_session:    true,
                confirm:        true,
                metadata:       { cart_mandate_id: cart_mandate.id },
              },
              { idempotency_key: "#{cart_mandate.id}-capture" },
            )
          rescue ::Stripe::CardError => e
            # A definitive decline: nothing was charged, so a retry is safe.
            raise PaymentFailed.new(card_decline_message(e), reason: :card_declined, retryable: true)
          rescue ::Stripe::StripeError
            # The outcome is unknown: a blind retry could double-charge.
            raise PaymentFailed.new(
              "the payment processor could not confirm the charge; its status is unknown",
              reason: :processor_unavailable, retryable: false,
            )
          end

        {
          psp_reference:        intent.id,
          settled_amount_cents: intent.amount_received,
          settled_at:           Time.at(intent.created).utc,
        }
      end

      # TEST-ONLY: saves a test card on the principal's Customer through a
      # confirmed SetupIntent and makes it the default, as the hosted page would.
      #
      # @return [String] the customer id
      def attach_test_card(user_id:, payment_method: "pm_card_visa")
        cus_id = ensure_customer(user_id)
        setup = ::Stripe::SetupIntent.create(
          {
            customer:             cus_id,
            payment_method:       payment_method,
            payment_method_types: ["card"],
            confirm:              true,
            usage:                "off_session",
          },
        )
        ::Stripe::Customer.update(
          cus_id,
          { invoice_settings: { default_payment_method: setup.payment_method } },
        )
        cus_id
      end

      private

      # The open `mode:setup` session for this customer and return target, or
      # nil. A failed lookup degrades to minting a fresh session, and says so.
      def outstanding_setup_session(cus_id, success_url:)
        listed = ::Stripe::Checkout::Session.list(
          customer: cus_id, status: "open", limit: SETUP_SESSION_LIST_LIMIT,
        )
        open_sessions = Array(listed&.data)
        match = open_sessions.find do |s|
          field(s, :mode) == "setup" &&
            field(s, :success_url) == success_url &&
            !field(s, :url).to_s.empty?
        end
        if match.nil? && open_sessions.size >= SETUP_SESSION_LIST_LIMIT
          log_warning("no reusable setup session among a full page of #{open_sessions.size} open " \
                      "Checkout Sessions; minting a fresh one, so setup_url may change between polls")
        end
        match
      rescue ::Stripe::StripeError => e
        log_warning("could not list open setup sessions (#{e.class}: #{e.message}); minting a " \
                    "fresh one, so setup_url changes between polls until this clears")
        nil
      end

      def log_warning(text)
        message = "[kiosk-pay-stripe] #{text}"
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : warn(message)
      end

      # The SDK's StripeObject raises NoMethodError for fields the API omitted.
      def field(obj, name)
        obj.respond_to?(name) ? obj.public_send(name) : nil
      end

      # A human-safe reason keyed on Stripe's stable error code; Stripe's own
      # message can carry request ids.
      def card_decline_message(error)
        case error.respond_to?(:code) ? error.code : nil
        when "expired_card"            then "the payment method has expired"
        when "insufficient_funds"      then "the payment method has insufficient funds"
        when "authentication_required" then "the payment method needs authentication an off-session charge cannot complete"
        else "the payment method was declined"
        end
      end

      def ensure_customer(user_id)
        existing = live_customer(user_id)
        return existing.id if existing

        cus = ::Stripe::Customer.create({ name: "principal-#{user_id}" })
        @customer_saver.call(user_id, cus.id)
        cus.id
      end

      # The principal's Stripe Customer, or nil when none is mapped or Stripe
      # no longer has the mapped one (deleted, or never in this account).
      def live_customer(user_id)
        cus_id = @customer_resolver.call(user_id)
        return nil unless cus_id

        customer = ::Stripe::Customer.retrieve(cus_id)
        customer unless customer.respond_to?(:deleted) && customer.deleted
      rescue ::Stripe::InvalidRequestError => e
        raise unless e.code == "resource_missing"
      end

      # The customer's default card, else its first attached one, else nil.
      def saved_payment_method_for(customer)
        customer.invoice_settings&.default_payment_method ||
          ::Stripe::PaymentMethod.list(customer: customer.id, type: "card").data.first&.id
      end
    end
  end
end

require "kiosk/payment_providers/stripe/charge_lookup"
