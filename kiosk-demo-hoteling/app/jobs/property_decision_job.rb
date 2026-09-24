# frozen_string_literal: true

# THE PROPERTY'S OWN ANSWER, minutes after the money arrived.
#
# Every other transition in this demo is something the caller asked for. This
# one is not: the guest has paid and is waiting, and a hotel desk takes a few
# minutes and sometimes says no. It is the clearest case the event stream
# exists for — there is no call to poll, because nothing was called.
#
# 80/20 and 2–5 minutes are DEMO NUMBERS, published rather than hidden, and
# both are configuration so a suite can force the branch and collapse the wait.
# A demo whose outcome is a coin toss with no seam is a flaky gate, and a flaky
# gate is one somebody switches off.
class PropertyDecisionJob < ApplicationJob
  queue_as :default

  def perform(booking_id)
    booking = Booking.find_by(id: booking_id)
    return unless booking
    # Somebody already resolved it — the guest confirmed, or this job ran
    # before. Both are fine and neither is an error: the decision is a
    # transition, not a schedule, and it happens once.
    return unless booking.status == Booking::RESERVED
    return unless booking.payment_status == Booking::PAID

    declined? ? decline!(booking) : accept!(booking)
  end

  private

  # ACCEPTING WRITES EXACTLY WHAT `confirm_booking` WRITES, and that is on
  # purpose: the guest may confirm first, and then this job finds the booking
  # already `confirmed` and returns above. The two paths converge on one row
  # rather than racing to two meanings of the word.
  def accept!(booking)
    code = booking.confirmation_code.presence || SecureRandom.uuid
    booking.update_columns(status: Booking::CONFIRMED, confirmation_code: code,
                           updated_at: Time.current)

    emit(booking, "confirmed", { "confirmation_code" => code })
  end

  # DECLINING RETURNS THE MONEY, through this demo's own {StubRefund} rather
  # than through the payment PORT. That boundary is deliberate and the reason is
  # written there: a reversal on `Kiosk::PaymentProviders::Base` is framework,
  # and what the framework absorbs owes a sentence in the published
  # specification describing it as wire behaviour. A hotel changing its mind is
  # this hotel's domain, not the protocol's.
  #
  # The nights are freed by the status alone: the overlap constraint and the
  # `live` scope are both scoped to reserved+confirmed, so a declined booking
  # stops holding its room without a second write.
  def decline!(booking)
    receipt = Kiosk.configuration.payment_provider.refund(
      booking_id: booking.id, amount_cents: booking.total_cents,
    )
    booking.update_columns(
      status:               Booking::DECLINED,
      payment_status:       Booking::REFUNDED,
      refunded_at:          Time.current,
      refund_psp_reference: receipt[:psp_reference],
      updated_at:           Time.current,
    )

    emit(booking, "declined", {
           "reason" => "property_declined",
           "refund" => { "amount_cents" => receipt[:amount_cents],
                         "currency" => receipt[:currency],
                         "psp_reference" => receipt[:psp_reference] },
         })
  end

  def emit(booking, status, extra)
    Kiosk::Server::Events.emit(
      topic: :booking_confirmation, subject: booking.id,
      identity_scope: [booking.user_id],
      data: { "booking_id" => booking.id, "status" => status }.merge(extra),
    )
  end

  def declined?
    rate = Rails.configuration.x.hoteling.decline_rate
    return false if rate.to_f <= 0
    return true  if rate.to_f >= 1

    Random.rand < rate.to_f
  end
end
