# frozen_string_literal: true

# What became of a capture this shop cannot account for locally: ask Stripe.
#
# A READ, and never a replay of the capture. Re-running the capture under its
# idempotency key returns the original PaymentIntent only when that request
# reached Stripe, and creates a second real charge when it did not.
#
# It answers about ONE cart mandate, and it answers with EVIDENCE rather than
# with a status: an intent counts only when it carries that mandate's id and
# charges that cart's amount in that cart's currency. A search that matched
# nothing, matched something else, or failed is `:unknown`, which is what keeps
# a claim in place — releasing one on an answer that is not about this cart is
# the blind retry that charges a human twice.
class StripeChargeLookup
  PAID        = "succeeded"
  # The two terminal states in which no money moved: the intent was cancelled,
  # or its off_session confirm was declined and it is waiting for a card that
  # will never come.
  NOT_CHARGED = %w[canceled requires_payment_method].freeze
  # The id lands inside a quoted value in Stripe's search query language. It
  # comes off the wire, so refuse a shape that could end that quote rather than
  # escape it.
  SEARCHABLE  = /\A[A-Za-z0-9._:-]+\z/

  # @param cart_mandate_id [String] the id the capture stamped on the intent
  # @param amount_cents [Integer] what that cart was to be charged
  # @param currency [String] the currency that cart was denominated in
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
