# frozen_string_literal: true

require "kiosk"
require "kiosk/payment_providers/stripe/version"

module Kiosk
  module PaymentProviders
    # Stripe PSP adapter (test mode for the PoC). See design spec §5.5 and
    # docs/architecture/payment-model.md.
    #
    # NOTE: always reference the SDK as `::Stripe` — bare `Stripe` resolves
    # to this class.
    #
    # ## SetupIntent / card-on-file model
    # The buyer's card is saved ONCE on the *provider's* Stripe account as a
    # Customer + PaymentMethod (keyed to the synthetic principal / user_id).
    # Subsequent purchases are charged `off_session` (merchant-initiated).
    #
    # The gem stays provider-agnostic: the principal→customer mapping is
    # injected by the host app (e.g. getgroceries) via `customer_resolver:`
    # and `customer_saver:` callables. No app table is touched inside this gem.
    class Stripe < Base
      VERSION = StripeVersion::VERSION

      # @param api_key [String] Stripe secret key (sk_test_… for the PoC)
      # @param test_payment_method [String, nil] Stripe test PaymentMethod id
      #   used as a back-compat fallback when no customer resolver is
      #   configured (e.g. early unit tests). Set to nil to disable the
      #   fallback and force the SetupIntent path.
      # @param customer_resolver [#call, nil] callable `(user_id) -> customer_id | nil`
      #   Looks up the saved Stripe Customer for a principal. Injected by the
      #   host (e.g. getgroceries); the gem never reads app tables directly.
      # @param customer_saver [#call, nil] callable `(user_id, customer_id) -> void`
      #   Persists a new principal→Customer mapping. Injected by the host.
      def initialize(api_key: nil, test_payment_method: "pm_card_visa",
                     customer_resolver: nil, customer_saver: nil)
        super()
        @api_key             = api_key || ENV.fetch("STRIPE_SECRET_KEY", nil)
        @test_payment_method = test_payment_method
        @customer_resolver   = customer_resolver
        @customer_saver      = customer_saver
        require "stripe"
        # PoC scope: this sets a PROCESS-GLOBAL Stripe key. Multiple adapter
        # instances with different keys would clobber each other; a future fix
        # uses per-request key options.
        ::Stripe.api_key = @api_key
      end

      # Resolve or create a Stripe Customer for the principal, then create a
      # Checkout Session in `mode: "setup"`. The human opens the returned URL
      # in a browser (NOT the chat) to enter their card on Stripe's hosted
      # page. The card is saved as a PaymentMethod on the Customer; the gem
      # never sees card data.
      #
      # @param user_id [String] synthetic principal identifier
      # @param return_url [String] URL Stripe redirects to on success or cancel
      # @return [String] hosted Stripe Checkout URL
      def setup_url(user_id:, return_url:)
        cus_id  = ensure_customer(user_id)
        session = ::Stripe::Checkout::Session.create(
          mode:        "setup",
          customer:    cus_id,
          success_url: return_url,
          cancel_url:  return_url,
        )
        session.url
      end

      # Returns true iff the resolved Customer has a usable saved card.
      # The assistant calls this before `pay`; if false, it triggers setup_url
      # and waits for the human to complete the SetupIntent.
      #
      # @param user_id [String]
      # @return [Boolean]
      def saved_method?(user_id:)
        cus_id = @customer_resolver&.call(user_id)
        return false unless cus_id

        customer = ::Stripe::Customer.retrieve(cus_id)
        return true if customer.invoice_settings&.default_payment_method

        pms = ::Stripe::PaymentMethod.list(customer: cus_id, type: "card")
        pms.data.any?
      end

      # Capture an AP2 cart mandate via an off_session (merchant-initiated)
      # PaymentIntent against the principal's saved card on the provider's
      # Stripe.
      #
      # Payment method resolution order:
      #   1. Explicit `payment_method:` argument (back-compat, e.g. tests).
      #   2. Customer's saved card (via `customer_resolver` + PM lookup).
      #   3. `@test_payment_method` fallback — ONLY when no `customer_resolver`
      #      is configured (pure back-compat mode without SetupIntent).
      #
      # If none of the above yields a PM, raises `SetupRequired`.
      #
      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @param payment_method [String, nil] explicit PM reference (optional)
      # @return [Hash] { psp_reference:, settled_amount_cents:, settled_at: }
      # @raise [Kiosk::PaymentProviders::SetupRequired] when no PM is available
      def capture(cart_mandate, payment_method: nil)
        pm     = non_empty(payment_method)
        cus_id = @customer_resolver&.call(cart_mandate.user_id)

        if pm.nil?
          if cus_id
            # SetupIntent path: use the principal's on-file card.
            pm = saved_payment_method_for(cus_id)
            raise SetupRequired unless pm
          else
            # Back-compat path: no resolver configured. Fall back to the test
            # PM (useful in unit tests / demos before SetupIntent is wired up).
            pm = non_empty(@test_payment_method) unless @customer_resolver
            raise SetupRequired unless pm
          end
        end

        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            customer:       cus_id,
            payment_method: pm,
            off_session:    true,
            confirm:        true,
            metadata:       { cart_mandate_id: cart_mandate.id },
          }.compact,
          { idempotency_key: "#{cart_mandate.id}-capture" },
        )

        {
          psp_reference:        intent.id,
          settled_amount_cents: intent.amount_received,
          # NOTE: intent.created is the PaymentIntent creation time — for this
          # synchronous off_session path it is the settlement time to within
          # seconds. A future deferred/manual-capture flow must source the
          # charge timestamp instead.
          settled_at:           Time.at(intent.created).utc,
        }
      end

      # Authorise a cart mandate: create a manual-capture hold on the PSP.
      #
      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @param payment_method [String] assistant-presented PSP payment-method reference
      # @return [Hash] { stripe_payment_intent_id:, client_secret:, status: }
      def authorize(cart_mandate, payment_method:)
        pm = non_empty(payment_method) || non_empty(@test_payment_method)
        raise ArgumentError, "no payment_method supplied" if pm.nil?

        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            payment_method: pm,
            confirm:        true,
            capture_method: "manual",
            metadata:       { cart_mandate_id: cart_mandate.id },
          },
          { idempotency_key: "#{cart_mandate.id}-auth" },
        )

        {
          stripe_payment_intent_id: intent.id,
          client_secret:            intent.client_secret,
          status:                   intent.status,
        }
      end

      # @param settlement [Kiosk::Mandate::Settlement]
      # @param amount_cents [Integer, nil] partial refund; nil = full
      # @return [Hash] { refund_id: }
      def refund(settlement, amount_cents = nil)
        params = { payment_intent: settlement.psp_reference }
        params[:amount] = amount_cents unless amount_cents.nil?

        refund = ::Stripe::Refund.create(params)
        { refund_id: refund.id }
      end

      # Programmatically attach a test card to the principal's Customer,
      # simulating a completed SetupIntent without a human at a hosted page.
      # Used by automated `rake demo` and integration specs.
      #
      # - Ensures a Customer exists (creates + saves via the saver if absent).
      # - Attaches the PaymentMethod to the Customer.
      # - Sets it as the Customer's default invoice payment method.
      #
      # @param user_id [String]
      # @param payment_method [String] Stripe test PM id (default: pm_card_visa)
      # @return [String] the customer_id
      def attach_test_card(user_id:, payment_method: "pm_card_visa")
        cus_id = ensure_customer(user_id)
        ::Stripe::PaymentMethod.attach(payment_method, { customer: cus_id })
        ::Stripe::Customer.update(
          cus_id,
          { invoice_settings: { default_payment_method: payment_method } },
        )
        cus_id
      end

      private

      # Resolve existing Customer or create a new one and persist the mapping
      # via the injected `customer_saver`.
      def ensure_customer(user_id)
        cus_id = @customer_resolver&.call(user_id)
        return cus_id if cus_id

        cus = ::Stripe::Customer.create({})
        @customer_saver&.call(user_id, cus.id)
        cus.id
      end

      # Return the PM id for a customer's default or first attached card.
      # Returns nil when no usable card is found.
      def saved_payment_method_for(cus_id)
        customer   = ::Stripe::Customer.retrieve(cus_id)
        default_pm = customer.invoice_settings&.default_payment_method
        return default_pm if default_pm

        pms = ::Stripe::PaymentMethod.list(customer: cus_id, type: "card")
        pms.data.first&.id
      end

      # Return the string as-is if non-empty, else nil.
      def non_empty(str)
        str && !str.empty? ? str : nil
      end
    end
  end
end
