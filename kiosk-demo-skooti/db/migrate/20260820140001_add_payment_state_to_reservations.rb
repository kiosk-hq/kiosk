# frozen_string_literal: true

# K-853: skooti had no payment lifecycle at all. The ONLY record that money had
# moved for a reservation was the engine's `kiosk.settlements` row, which is
# written AFTER the irreversible capture — so between the capture returning and
# that row landing, skooti's own records said "no settlement for this
# reservation", and `my_reservations` published nothing about money whatsoever.
#
# protocol.md §11.6 forbids exactly that answer: paid state MUST be anchored to
# the CAPTURE, not to the settlement record, and an operator MUST NOT report a
# rental as not paid while a capture for its cart mandate may still be
# outstanding. "No settlement row, therefore no charge" is the guess that tells
# an assistant to sign a fresh chain and charge its human twice.
#
#   payment_status     — unpaid → paying → paid. `paying` is CLAIMED atomically
#                        before the cashier check and the capture, which is what
#                        makes a second capture for the same reservation
#                        impossible; `paid` is flipped the instant the capture
#                        RETURNS, a hair before the engine writes the settlement.
#   paid_by_user_id    — WHO paid, written by the same claim from the SIGNED
#                        cart mandate. skooti's cashier deliberately does not
#                        check that the payer owns the reservation (ownership is
#                        a USE-time gate on start_rental / rent_motorcycle, and
#                        the isolation flow proves B may pay for A's
#                        reservation), so the capture-anchored marker has to
#                        carry the payer or the payment gate could not stay
#                        principal-scoped during the window.
#
# Deliberately a SEPARATE column rather than more values in
# `reservations.status`: that column is the RIDE's lifecycle (reserved →
# active), read by `still_reserved` to make a second activation a refusal.
# Payment is an orthogonal axis and gets its own.
class AddPaymentStateToReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :reservations, :payment_status,  :string, null: false, default: "unpaid"
    add_column :reservations, :paid_by_user_id, :uuid
  end
end
