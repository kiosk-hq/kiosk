# frozen_string_literal: true

module Kiosk
  # AP2 (Agent Payments Protocol) mandate value objects.
  # See design spec §5.5 «Agent payments (AP2)».
  #
  # The mandate trio:
  #
  #   1. IntentMandate  — user → agent: «this much, for this purpose,
  #                                      until this time».
  #   2. CartMandate    — agent ↔ provider: «these line items at this
  #                                          price, bound to the intent».
  #   3. PaymentMandate — settlement attestation: «PSP settled this cart».
  #
  # Each is signed (JWS) by the agent: `signer = agent_id`,
  # `subject = user_id`. `iss` MUST equal `kiosk.issuer` from
  # `/.well-known/kiosk.json` (spec §3.4) — mismatch is treated as forged
  # provenance and rejected.
  #
  # The value objects below carry the parsed/verified content; the raw JWS
  # string lives in the `*_mandates` Postgres tables and on the wire.
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
      :id, :cart_mandate_id, :user_id, :agent_id, :issuer, :psp_reference,
      :settled_amount_cents, :currency, :settled_at, :raw_jws
    )
  end
end
