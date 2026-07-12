# frozen_string_literal: true

module Kiosk
  # AP2 (Agent Payments Protocol) mandate value objects.
  # See the Payment (AP2 mandate chain) section of the spec.
  #
  # The AP2 mandate trio — all three are signed JWS tokens issued by the
  # assistant and verified by the provider:
  #
  #   1. IntentMandate   — assistant presents to provider: «my user authorises
  #                        up to this amount, for this purpose, until this
  #                        expiry».
  #   2. CartMandate     — assistant commits to: «these line items at this
  #                        total, bound to the intent above».
  #   3. PaymentMandate  — assistant presents its payment credential: «charge
  #                        this payment method for this amount, against that
  #                        cart».
  #
  # Each mandate is signed by the assistant's registered key (`agent_id`),
  # with `subject = user_id`. `iss` MUST equal `kiosk.issuer` from
  # `/.well-known/kiosk.json` — mismatch is treated as forged
  # provenance and rejected.
  #
  # After the provider's PSP captures the charge it records a settlement — an
  # unsigned server-minted receipt attesting «PSP settled this cart»
  # (psp_reference, settled amount, timestamp). That receipt is not a signed
  # mandate and has no value type here: the PSP adapter returns it as a plain
  # hash and kiosk-server persists it straight into the `settlements` table.
  #
  # The value objects below carry the parsed/verified content; the raw JWS
  # string lives in the corresponding Postgres tables and on the wire.
  module Mandate
    IntentMandate = Data.define(
      :id, :user_id, :agent_id, :issuer, :scope, :cap_amount_cents, :currency,
      :expires_at, :created_at, :raw_jws
    )

    CartMandate = Data.define(
      :id, :intent_mandate_id, :user_id, :agent_id, :issuer, :line_items,
      :total_amount_cents, :currency, :expires_at, :created_at, :raw_jws
    )

    # The third AP2 mandate: the assistant presents a payment credential.
    # Signed by the assistant and verified by the provider before capture.
    # Carries the payment-method reference the PSP will charge.
    PaymentMandate = Data.define(
      :id, :cart_mandate_id, :user_id, :agent_id, :issuer, :payment_method,
      :amount_cents, :currency, :expires_at, :created_at, :raw_jws
    )
  end
end
