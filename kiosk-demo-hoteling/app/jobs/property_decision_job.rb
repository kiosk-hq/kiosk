# frozen_string_literal: true

# The property's answer to a paid booking: it accepts and mints the
# confirmation code, or declines, cancels the booking and refunds the charge.
# The wait and the decline rate are configuration (`config.x.hoteling`). The
# booking row stays locked until the answer is saved, so a second run answers
# nothing.
class PropertyDecisionJob < ApplicationJob
  queue_as :default

  def perform(booking_id)
    Booking.transaction do
      booking = Booking.lock.reserved.paid.find_by(id: booking_id)
      next unless booking

      declines? ? decline!(booking) : accept!(booking)
    end
  end

  private

  # The code is six digits that a guest reads out at the desk. A code that the
  # property already gave is drawn again.
  def accept!(booking)
    code = format('%06d', SecureRandom.random_number(1_000_000))
    Booking.transaction(requires_new: true) { booking.update!(status: :confirmed, confirmation_code: code) }

    emit(booking, 'confirmed', { 'confirmation_code' => code })
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # A booking with no settlement was never charged: cancelled, nothing refunded.
  def decline!(booking)
    charge  = booking.settlement&.psp_reference
    receipt = charge && claim.refund(psp_reference: charge, amount_cents: booking.total_cents, key: booking.id)
    cancel!(booking, receipt)

    claim.announce(booking.id, 'refunded') if receipt
    emit(booking, 'cancelled', { 'reason' => 'property_declined', **refund_news(booking, receipt, charge) })
  end

  def cancel!(booking, receipt)
    booking.status = :cancelled
    if receipt
      booking.payment_status       = :refunded
      booking.refund_psp_reference = receipt[:psp_reference]
    end
    booking.save!
  end

  def refund_news(booking, receipt, charge)
    return {} unless receipt

    { 'refund' => { 'amount_cents' => booking.total_cents,
                    'currency' => 'eur',
                    'psp_reference' => receipt[:psp_reference],
                    'reverses' => charge } }
  end

  def claim = Kiosk.configuration.payment_provider

  def emit(booking, status, extra)
    Kiosk::Server::Events.emit(
      topic: :booking_confirmation, subject: booking.id, identity_scope: [booking.user_id],
      data: { 'booking_id' => booking.id, 'status' => status }.merge(extra)
    )
  end

  def declines?
    Random.rand < Rails.configuration.x.hoteling.decline_rate.to_f
  end
end
