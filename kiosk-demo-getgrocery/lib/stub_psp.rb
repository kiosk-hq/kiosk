# frozen_string_literal: true

# E2E test PSP: a deterministic in-process Kiosk payment provider. No real
# Stripe — proves the server-side register→mandate→pay→persist flow. Returns
# the settlement shape verb_pay expects (psp_reference, settled_amount_cents,
# settled_at).
class StubPsp < Kiosk::PaymentProviders::Base
  def capture(cart_mandate)
    {
      psp_reference:        "stub_pi_#{cart_mandate.id}",
      settled_amount_cents: cart_mandate.total_amount_cents,
      settled_at:           Time.now.utc,
    }
  end
end
