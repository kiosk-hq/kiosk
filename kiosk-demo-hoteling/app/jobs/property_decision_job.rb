# frozen_string_literal: true

# The property's answer to a paid booking: it accepts and mints the
# confirmation code, or declines, cancels the booking and refunds the charge.
# The wait and the decline rate are configuration (`config.x.hoteling`).
class PropertyDecisionJob < ApplicationJob
  queue_as :default

  def perform(booking_id)
    booking = Booking.reserved.paid.find_by(id: booking_id)
    return unless booking

    declines? ? decline!(booking) : accept!(booking)
  end

  private

  def accept!(booking)
    code = booking.confirmation_code.presence || SecureRandom.uuid
    booking.update!(status: :confirmed, confirmation_code: code)

    emit(booking, "confirmed", { "confirmation_code" => code })
  end

  # A booking with no settlement was never charged: cancelled, nothing refunded.
  def decline!(booking)
    charge  = settled_reference(booking)
    receipt = charge && refund!(charge, booking.total_cents)

    booking.status = :cancelled
    if receipt
      booking.payment_status       = :refunded
      booking.refunded_at          = Time.current
      booking.refund_psp_reference = receipt[:psp_reference]
    end
    booking.save!

    refund = if receipt
               { "refund" => { "amount_cents"  => booking.total_cents,
                               "currency"      => "eur",
                               "psp_reference" => receipt[:psp_reference],
                               "reverses"      => charge } }
             end
    emit(booking, "cancelled", { "reason" => "property_declined", **refund.to_h })
  end

  def settled_reference(booking)
    Kiosk::Settlement.joins(:cart_mandate)
                     .merge(Kiosk::CartMandate.referencing(booking_id: booking.id))
                     .order(:created_at).pick(:psp_reference)
  end

  def refund!(psp_reference, amount_cents)
    Kiosk.configuration.payment_provider.refund(psp_reference: psp_reference, amount_cents: amount_cents)
  end

  def emit(booking, status, extra)
    Kiosk::Server::Events.emit(
      topic: :booking_confirmation, subject: booking.id, identity_scope: [booking.user_id],
      data: { "booking_id" => booking.id, "status" => status }.merge(extra),
    )
  end

  def declines?
    Random.rand < Rails.configuration.x.hoteling.decline_rate.to_f
  end
end
