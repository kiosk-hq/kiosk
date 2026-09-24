# frozen_string_literal: true

# The reversal, when the property declines a booking that was already paid.
#
# == Why it is a service of its own and not a method on StubPsp
#
# `StubPsp` is held in lockstep with skooti's copy and with the e2e harness's
# fixture, because all three must keep returning the one settlement shape
# `verb_pay` reads. Skooti's rentals have no answer to reverse and the harness
# drives no decline, so putting a `#refund` there would mean carrying a method
# nobody calls in two files to keep a diff quiet — which is the opposite of
# what a demo is for.
#
# == And why it is not on the payment PORT either
#
# `Kiosk::PaymentProviders::Base` would make the reversal FRAMEWORK, and what
# the framework absorbs owes a sentence in the published specification
# describing it as wire behaviour. A hotel changing its mind after taking the
# money is this demo's domain: two operators in different languages would each
# handle it differently and both be right, which is the test for where it
# belongs.
#
# == What it is honest about
#
# There is no PSP here. `StubPsp` settles deterministically in-process, so a
# reversal of it is equally deterministic, and the reference below is a receipt
# in the same shape rather than a claim that money moved at a provider. A demo
# on a real Stripe key would call `Stripe::Refund.create` here and return what
# it answered; the CALLER does not change.
class StubRefund
  def self.call(booking_id:, amount_cents:, currency: "eur")
    {
      psp_reference: "stub_re_#{booking_id}",
      amount_cents:  amount_cents,
      currency:      currency,
      refunded_at:   Time.now.utc,
    }
  end
end
