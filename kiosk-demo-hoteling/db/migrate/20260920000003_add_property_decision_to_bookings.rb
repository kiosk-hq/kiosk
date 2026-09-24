# frozen_string_literal: true

# The property's own answer, which arrives minutes after the money does.
#
# Until now a booking went `reserved → confirmed` the moment its payer asked,
# and the hotel was never consulted. Real desks take a few minutes and
# sometimes say no — so a booking now carries WHEN the property is due to
# decide, and, when it declines, what became of the money.
#
# `refund_psp_reference` is the receipt for the reversal, kept for the same
# reason a settlement keeps `psp_reference`: an assistant telling its human
# «you were refunded» must be able to point at something the operator wrote
# down rather than at a status word.
class AddPropertyDecisionToBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :bookings, :decision_due_at,      :datetime
    add_column :bookings, :refunded_at,          :datetime
    add_column :bookings, :refund_psp_reference, :string
  end
end
