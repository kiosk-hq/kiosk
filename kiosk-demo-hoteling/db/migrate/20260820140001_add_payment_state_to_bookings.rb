# frozen_string_literal: true

# Without a payment lifecycle of its own, the ONLY record that money had moved
# for a booking would be the engine's `kiosk.settlements` row, which is written
# AFTER the irreversible capture — so between the capture returning and that row
# landing, hoteling's own records would say "no settlement for this booking",
# and `my_bookings` would publish nothing about money whatsoever.
#
# protocol.md §11.6 forbids exactly that answer: paid state MUST be anchored to
# the CAPTURE, not to the settlement record, and an operator MUST NOT report a
# booking as not paid while a capture for its cart mandate may still be
# outstanding. "No settlement row, therefore no charge" is the guess that tells
# an assistant to sign a fresh chain and charge its human twice.
#
#   payment_status     — unpaid → paying → paid. `paying` is CLAIMED atomically
#                        before the cashier check and the capture, which is what
#                        makes a second capture for the same booking impossible;
#                        `paid` is flipped the instant the capture RETURNS, a
#                        hair before the engine writes the settlement.
#   paid_by_user_id    — WHO paid, written by the same claim from the SIGNED
#                        cart mandate. hoteling's cashier deliberately does not
#                        check that the payer owns the booking (ownership is a
#                        USE-time gate — confirm_booking Gate 1 — and the
#                        isolation flow proves B may pay for A's booking), so
#                        the capture-anchored marker has to carry the payer or
#                        `confirm_booking`'s payment gate could not stay
#                        principal-scoped during the window.
#
# Deliberately a SEPARATE column rather than more values in `bookings.status`:
# that column is the room-night lifecycle (reserved/confirmed/cancelled) and the
# `bookings_no_overlapping_room_nights` EXCLUDE constraint is scoped to two of
# its values. Payment is an orthogonal axis and gets its own.
class AddPaymentStateToBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :bookings, :payment_status,  :string, null: false, default: "unpaid"
    add_column :bookings, :paid_by_user_id, :uuid
  end
end
