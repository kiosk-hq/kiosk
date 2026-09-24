# frozen_string_literal: true

# Demo stub PSP: a deterministic in-process Kiosk payment provider. No real
# Stripe — proves the server-side register→mandate→pay→persist flow. Returns
# the settlement shape verb_pay expects (psp_reference, settled_amount_cents,
# settled_at).
class StubPsp < Kiosk::PaymentProviders::Base
  def capture(cart_mandate, payment_method:)
    {
      psp_reference:        "stub_pi_#{cart_mandate.id}",
      settled_amount_cents: cart_mandate.total_amount_cents,
      settled_at:           Time.now.utc,
    }
  end

  # REVERSE A CAPTURE, on the operator's signal — the money goes back to the
  # card it came from. A stub PSP that could only take money would be a stub of
  # half a payment provider, and the half it left out is the one an operator
  # needs the day it cannot honour what it sold.
  #
  # It names the ORIGINAL charge rather than a booking or an order, because that
  # is what a reversal is against at any real provider (`Stripe::Refund.create`
  # takes a `payment_intent:`) and it is what makes «the buyer got their money
  # back» checkable: the receipt points at the charge it undid.
  def refund(psp_reference:, amount_cents:)
    {
      psp_reference:        "stub_re_#{psp_reference}",
      refunded_psp_reference: psp_reference,
      refunded_amount_cents: amount_cents,
      refunded_at:          Time.now.utc,
    }
  end

end
