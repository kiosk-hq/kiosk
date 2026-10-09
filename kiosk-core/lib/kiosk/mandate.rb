# frozen_string_literal: true

module Kiosk
  # AP2 (Agent Payments Protocol) mandate value objects.
  # Each is a JWS the assistant signs; its `iss` must equal the origin's issuer.
  module Mandate
    IntentMandate = Data.define(
      :id, :user_id, :agent_id, :issuer, :scope, :cap_amount_cents, :currency,
      :expires_at, :created_at, :raw_jws
    )

    CartMandate = Data.define(
      :id, :intent_mandate_id, :user_id, :agent_id, :issuer, :line_items,
      :total_amount_cents, :currency, :expires_at, :created_at, :raw_jws
    )

    PaymentMandate = Data.define(
      :id, :cart_mandate_id, :user_id, :agent_id, :issuer, :payment_method,
      :amount_cents, :currency, :expires_at, :created_at, :raw_jws
    )
  end
end
