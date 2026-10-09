# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # What became of a capture the operator cannot account for locally, read from
      # Stripe by the `metadata.cart_mandate_id` every capture stamps — never a replay.
      # Only an intent matching this cart's id, amount and currency counts; anything else is `:unknown`.
      class ChargeLookup
        PAID        = "succeeded"
        # Terminal states in which no money moved.
        NOT_CHARGED = %w[canceled requires_payment_method].freeze
        # The id comes off the wire into a quoted search value: refuse what could end the quote.
        SEARCHABLE  = /\A[A-Za-z0-9._:-]+\z/

        def initialize
          require "stripe"
        end

        # @return [Symbol] :paid, :not_charged or :unknown
        def outcome(cart_mandate_id:, amount_cents:, currency:)
          return :unknown unless SEARCHABLE.match?(cart_mandate_id)

          intents = search(cart_mandate_id).select do |intent|
            charges_this_cart?(intent, cart_mandate_id, amount_cents, currency)
          end

          return :unknown     if intents.empty?
          return :paid        if intents.any? { |intent| intent.status == PAID }
          return :not_charged if intents.all? { |intent| NOT_CHARGED.include?(intent.status) }

          :unknown
        rescue ::Stripe::StripeError
          :unknown
        end

        private

        def search(cart_mandate_id)
          ::Stripe::PaymentIntent.search(query: "metadata['cart_mandate_id']:'#{cart_mandate_id}'").data
        end

        def charges_this_cart?(intent, cart_mandate_id, amount_cents, currency)
          intent.metadata["cart_mandate_id"].to_s == cart_mandate_id &&
            intent.amount.to_i == amount_cents.to_i &&
            intent.currency.to_s.downcase == currency.to_s.downcase
        end
      end
    end
  end
end
