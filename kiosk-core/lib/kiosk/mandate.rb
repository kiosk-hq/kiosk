# frozen_string_literal: true

module Kiosk
  # AP2 (Agent Payments Protocol) mandate value objects.
  # Each is a closed AP2 v0.2 mandate: an SD-JWT the assistant signs with its
  # registered key. `reference` is the base64url SHA-256 of the presented SD-JWT.
  module Mandate
    # Binds the operator-signed checkout by `checkout_hash`; the line items,
    # total and currency come from that checkout.
    CheckoutMandate = Data.define(
      :reference, :checkout_hash, :user_id, :agent_id, :issuer, :line_items,
      :total_amount_cents, :currency, :expires_at, :sd_jwt
    )

    # Pays for the checkout whose hash is `transaction_id`. `payment_instrument`
    # is the instrument id: a PSP payment-method id, or `on_file`.
    PaymentMandate = Data.define(
      :reference, :transaction_id, :user_id, :agent_id, :issuer, :payment_instrument,
      :amount_cents, :currency, :expires_at, :sd_jwt
    )
  end
end
