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
    # Already answered — this job ran before. The decision is a transition, not
    # a schedule: it happens once, and the PROPERTY is the only thing that makes
    # it. Nothing else in this demo writes `confirmed` or `cancelled`.
    return unless booking.status == Booking::RESERVED
    return unless booking.payment_status == Booking::PAID

    declines? ? decline!(booking) : accept!(booking)
  end

  private

  # ACCEPTING IS WHAT MINTS THE CONFIRMATION CODE. The guest does not confirm
  # their own booking — a hotel does — so this is the only place the code comes
  # from, and `confirm_booking` reads it back rather than writing it.
  def accept!(booking)
    code = booking.confirmation_code.presence || SecureRandom.uuid
    booking.update_columns(status: Booking::CONFIRMED, confirmation_code: code,
                           updated_at: Time.current)

    emit(booking, "confirmed", { "confirmation_code" => code })
  end

  # DECLINING CANCELS THE BOOKING AND GIVES THE MONEY BACK — to the card it came
  # from, by reversing the CHARGE this operator made. The reversal is told which
  # charge to undo (`psp_reference` off the settlement the engine wrote), which
  # is what a refund is against at any real provider and what makes «the buyer
  # was paid back» a checkable fact rather than a status word.
  #
  # The nights are freed by the status alone: the overlap constraint and the
  # `live` scope are both scoped to reserved+confirmed, so a cancelled booking
  # stops holding its room without a second write.
  #
  # A booking with no settlement to reverse is cancelled anyway and says so with
  # no `refund` block. It is the shape of a capture that never landed, and
  # leaving the guest holding a cancelled booking they were never charged for is
  # the right answer — inventing a refund receipt for a charge that does not
  # exist would not be.
  def decline!(booking)
    charge  = settled_reference(booking)
    receipt = charge && refund!(charge, booking.total_cents)

    booking.update_columns(
      { status:         Booking::CANCELLED,
        payment_status: receipt ? Booking::REFUNDED : booking.payment_status,
        refunded_at:    (Time.current if receipt),
        refund_psp_reference: receipt&.fetch(:psp_reference, nil),
        updated_at:     Time.current }.compact,
    )

    refund_block = receipt && {
      "amount_cents"  => booking.total_cents,
      "currency"      => "eur",
      "psp_reference" => receipt[:psp_reference],
      "reverses"      => charge,
    }
    emit(booking, "cancelled",
         { "reason" => "property_declined" }.merge(refund_block ? { "refund" => refund_block } : {}))
  end

  # The engine writes the settlement in executor phase 3, AFTER the capture
  # returns, so this is the operator's own record of the charge it made.
  def settled_reference(booking)
    Settlement.joins(:cart_mandate)
              .merge(CartMandate.referencing(booking.id))
              .order(:created_at).pick(:psp_reference)
  end

  def refund!(psp_reference, amount_cents)
    Kiosk.configuration.payment_provider.refund(
      psp_reference: psp_reference, amount_cents: amount_cents,
    )
  end

  def emit(booking, status, extra)
    Kiosk::Server::Events.emit(
      topic: :booking_confirmation, subject: booking.id,
      identity_scope: [booking.user_id],
      data: { "booking_id" => booking.id, "status" => status }.merge(extra),
    )
  end

  def declines?
    rate = Rails.configuration.x.hoteling.decline_rate
    return false if rate.to_f <= 0
    return true  if rate.to_f >= 1

    Random.rand < rate.to_f
  end
end
