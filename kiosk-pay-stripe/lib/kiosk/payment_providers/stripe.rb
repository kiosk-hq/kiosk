# frozen_string_literal: true

require "kiosk"
require "kiosk/payment_providers/stripe/version"

module Kiosk
  module PaymentProviders
    # Stripe PSP adapter (test mode for the PoC). See the Payment section
    # of the spec.
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
    # injected by the host app (e.g. getgrocery) via `customer_resolver:`
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
      #   host (e.g. getgrocery); the gem never reads app tables directly.
      # @param customer_saver [#call, nil] callable `(user_id, customer_id) -> void`
      #   Persists a new principal→Customer mapping. Injected by the host.
      # @param test_autocard [Boolean] TEST-ONLY. When true, the adapter
      #   simulates a completed SetupIntent (auto-attaches a test card at
      #   capture) instead of requiring the human's hosted card entry — so
      #   automated suites (demo drivers, redteam, isolation) need no card-setup
      #   step and no server-side test route. The host sets this ONLY in a test
      #   environment (e.g. getgrocery when KIOSK_TEST_AUTOCARD=1); it is
      #   never enabled in production or the live demo, where the real hosted
      #   SetupIntent flow runs.
      def initialize(api_key: nil, test_payment_method: "pm_card_visa",
                     customer_resolver: nil, customer_saver: nil, test_autocard: false,
                     return_url: nil)
        super()
        @api_key             = api_key || ENV.fetch("STRIPE_SECRET_KEY", nil)
        @test_payment_method = test_payment_method
        @customer_resolver   = customer_resolver
        @customer_saver      = customer_saver
        @test_autocard       = test_autocard
        @return_url          = return_url
        require "stripe"
        # PoC scope: this sets a PROCESS-GLOBAL Stripe key. Multiple adapter
        # instances with different keys would clobber each other; a future fix
        # uses per-request key options.
        ::Stripe.api_key = @api_key
      end

      # Resolve or create a Stripe Customer for the principal, then return a
      # hosted Checkout Session URL in `mode: "setup"`. The human opens it in a
      # browser (NOT the chat) to enter their card on Stripe's hosted page. The
      # card is saved as a PaymentMethod on the Customer; the gem never sees
      # card data.
      #
      # ## STABLE ACROSS POLLS (K-492)
      # Hosts document `payment_setup` as the readiness probe an assistant POLLS
      # while its human is still at the hosted page, so this call must not mint a
      # session per poll. It reuses the `mode:setup` Checkout Session already
      # OUTSTANDING for this customer when there is one, and only creates a new
      # session when there is not. Observed live before the fix: FIVE sessions
      # for ONE card setup at a ~4 s poll cadence — the assistant held a
      # different url after every poll, and relaying the newest one mid-flow
      # drops the human off the page they are filling in.
      #
      # The wire shape is unchanged (still a hosted Checkout URL); only the
      # url's stability is.
      #
      # @param user_id [String] synthetic principal identifier
      # @return [String] hosted Stripe Checkout URL
      def setup_url(user_id:)
        # Resolve the return URL FIRST: it fails LOUD when nothing is configured
        # (K-553), and that must happen before ANY Stripe call — the reuse
        # lookup included — so a misconfigured deploy still crashes loudly
        # instead of listing sessions it could never match.
        success_url = resolved_return_url
        cus_id      = ensure_customer(user_id)

        outstanding_setup_session(cus_id, success_url: success_url)&.url ||
          ::Stripe::Checkout::Session.create(
            mode:                    "setup",
            customer:                cus_id,
            payment_method_types:    ["card"],
            success_url:             success_url,
          ).url
      end

      # Returns true when the principal MUST complete a Stripe SetupIntent
      # before a charge can proceed (overrides Base#setup_required?).
      #
      # Only meaningful when a customer_resolver is configured (SetupIntent
      # model).  When there is no resolver the adapter operates in back-compat
      # mode (explicit PM or test_payment_method fallback) and setup is never
      # required from the server side.
      #
      # @param user_id [String]
      # @return [Boolean]
      def setup_required?(user_id:)
        return false unless @customer_resolver
        return false if @test_autocard  # test mode: card auto-provisioned at capture

        !saved_method?(user_id: user_id)
      end

      # Returns true iff the resolved Customer has a usable saved card.
      # Internal predicate for `setup_required?` (its sole caller); callers
      # gate on `setup_required?`, not this, so the adapter's policy
      # (e.g. test_autocard) is honoured.
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
        if @customer_resolver
          # SetupIntent model: the principal's card is on file. Resolve the
          # customer (no customer ⇒ the principal must set up a card first) and
          # charge its saved card. The mandate's payment_method is deliberately
          # ignored — in this model the assistant authorizes, never presents a card.
          cus_id = @customer_resolver.call(cart_mandate.user_id)
          # TEST-ONLY: simulate the human's completed SetupIntent so automated
          # suites need no card-setup step. Never enabled in prod/live demo.
          if @test_autocard && (cus_id.nil? || saved_payment_method_for(cus_id).nil?)
            cus_id = attach_test_card(user_id: cart_mandate.user_id)
          end
          raise SetupRequired unless cus_id
          pm = saved_payment_method_for(cus_id) || raise(SetupRequired)
        else
          # No resolver (unit tests / pre-SetupIntent demos): use an explicitly
          # presented PM, else the configured test fallback.
          cus_id = nil
          pm = non_empty(payment_method) || non_empty(@test_payment_method) || raise(SetupRequired)
        end

        intent =
          begin
            ::Stripe::PaymentIntent.create(
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
          rescue ::Stripe::CardError => e
            # A card DECLINE (card_declined / expired_card / insufficient_funds /
            # authentication_required). Stripe raises CardError only after a
            # DEFINITIVE decision — NO money moved — so this is safe to retry.
            # Translate to a PSP-agnostic PaymentFailed with a human-safe message
            # (never the raw Stripe message, which can carry request ids etc.).
            raise PaymentFailed.new(card_decline_message(e), reason: :card_declined, retryable: true)
          rescue ::Stripe::StripeError
            # Timeout / connectivity / API error: the charge outcome is UNKNOWN
            # (Stripe may or may not have captured). NOT safe to blind-retry —
            # the caller must reconcile before trying again (K-545). No raw PSP
            # detail is surfaced.
            raise PaymentFailed.new(
              "the payment processor could not confirm the charge; its status is unknown",
              reason: :processor_unavailable, retryable: false,
            )
          end

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
        # Save the card the faithful way — a real SetupIntent (exactly what the
        # human's hosted-page flow does), confirmed with the test PM. Stripe
        # attaches a fresh PaymentMethod to the customer and returns its id;
        # that returned id (NOT the shared "pm_card_visa" token) is what we set
        # as the default and later charge off_session.
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

      # The `mode:setup` Checkout Session already outstanding for this customer,
      # or nil when there is none to reuse (K-492).
      #
      # "Outstanding" means Stripe still lists it as `status: "open"` — i.e. the
      # human has neither completed it nor let it expire (a Checkout Session
      # expires ~24 h after creation, after which Stripe reports `expired` and
      # this returns nil so a fresh one is minted). We additionally require the
      # session to target the SAME `success_url` we would create now, so an
      # operator that re-pointed its origin never hands the human a stale return
      # target — and so a fixture-returning stub (stripe-mock) cannot be
      # mistaken for a real outstanding session.
      #
      # BEST EFFORT, BUT NEVER SILENT: a Stripe error while looking up degrades
      # to minting a fresh session (the pre-K-492 behaviour) — a readiness probe
      # must not start failing because a list call did — but "the lookup broke"
      # is NOT the same fact as "there is no outstanding session", so it is
      # LOGGED. Without that line the two are indistinguishable from outside,
      # and a wrong filter, a renamed field or an API change silently reverts
      # the fix to one session per poll while every response still looks
      # perfectly healthy.
      def outstanding_setup_session(cus_id, success_url:)
        listed = ::Stripe::Checkout::Session.list(customer: cus_id, status: "open", limit: 10)
        Array(listed&.data).find do |s|
          field(s, :mode) == "setup" &&
            field(s, :success_url) == success_url &&
            !field(s, :url).to_s.empty?
        end
      rescue ::Stripe::StripeError => e
        log_setup_session_lookup_failed(e)
        nil
      end

      # Say out loud that the K-492 reuse lookup did not answer, so degrading to
      # a fresh session is visible in the operator's log instead of passing for
      # the happy path. Operator-side only — nothing here reaches the wire.
      def log_setup_session_lookup_failed(error)
        message = "[kiosk-pay-stripe] could not check for an outstanding setup session " \
                  "(#{error.class}: #{error.message}) — minting a FRESH Checkout Session, so " \
                  "setup_url is NOT stable across polls until this clears (K-492)."
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : warn(message)
      end

      # Read a field off a Stripe object without assuming it is present — the
      # SDK's StripeObject raises NoMethodError for fields the API omitted.
      def field(obj, name)
        obj.respond_to?(name) ? obj.public_send(name) : nil
      end

      # Map a Stripe::CardError to a short, human-safe, PSP-agnostic reason.
      # Keyed on the stable Stripe error `code` so no raw Stripe message (which
      # can embed request ids / internal detail) reaches the wire. Falls back to
      # a generic decline message for any unmapped code.
      def card_decline_message(error)
        case error.respond_to?(:code) ? error.code : nil
        when "expired_card"            then "the payment method has expired"
        when "insufficient_funds"      then "the payment method has insufficient funds"
        when "authentication_required" then "the payment method needs authentication an off-session charge cannot complete"
        else "the payment method was declined"
        end
      end

      # The `success_url` Stripe redirects the human's BROWSER to after they
      # enter a card on the hosted page. It MUST be a real, operator-owned
      # origin: a hardcoded localhost fallback would send a paying customer to
      # their OWN machine on a deploy that forgot to wire it (K-553). Resolution
      # order:
      #   1. the explicit return_url the host injected (e.g. getgrocery passes
      #      "#{Kiosk.configuration.issuer}/payment/return");
      #   2. else derive it from the configured Kiosk issuer/origin — the
      #      operator's real https origin in production (fail-loud per K-510) and
      #      localhost:PORT in local dev, so it is correct in both WITHOUT ever
      #      hardcoding localhost;
      #   3. else (no return_url and no configured issuer) fail LOUD — a hosted
      #      SetupIntent with no valid return target is a misconfiguration, not
      #      something to paper over with a localhost address a real human's
      #      browser would follow.
      def resolved_return_url
        return @return_url if @return_url && !@return_url.to_s.strip.empty?

        issuer = configured_issuer
        return "#{issuer.to_s.chomp("/")}/payment/return" unless issuer.to_s.strip.empty?

        raise "Stripe SetupIntent needs a return URL (success_url) but none is configured. " \
              "Pass return_url: to Kiosk::PaymentProviders::Stripe.new " \
              "(e.g. \"\#{Kiosk.configuration.issuer}/payment/return\"), or configure Kiosk's " \
              "issuer so it can be derived. A localhost fallback is refused because it would " \
              "send the paying human's browser to their own machine (K-553)."
      end

      # The configured Kiosk issuer/origin, or nil if Kiosk is not configured
      # (e.g. this adapter used in isolation). Never raises.
      def configured_issuer
        return nil unless defined?(Kiosk) && Kiosk.respond_to?(:configuration)

        Kiosk.configuration&.issuer
      rescue StandardError
        nil
      end

      # Resolve existing Customer or create a new one and persist the mapping
      # via the injected `customer_saver`.
      def ensure_customer(user_id)
        cus_id = @customer_resolver&.call(user_id)
        return cus_id if cus_id

        cus = ::Stripe::Customer.create({ name: "principal-#{user_id}" })
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
