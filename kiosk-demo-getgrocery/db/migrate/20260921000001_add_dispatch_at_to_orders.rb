# frozen_string_literal: true

# ── WHEN THE COURIER LEAVES IS A FACT ABOUT THE ORDER, NOT A QUEUE ENTRY ────
#
# A paid order is delivered in a window this shop already published, and the
# courier sets off shortly BEFORE that window opens. This column records that
# instant — `slot_at` minus the lead the shop picked for this order — so the
# pending work is legible in the table an operator already reads. A queue entry
# is not: `:async` keeps its schedule in memory, and a demo whose only record of
# «something is due» lives inside a thread pool teaches an adopter to look in
# the wrong place.
#
# IT IS NULLABLE, AND THAT IS THE POINT. An order is armed when it is PAID,
# which is a different moment from when it is written, and a rescheduled order
# is re-armed against its new window. NULL means «no courier is due yet», which
# is the true state of an unpaid basket; a default would have to invent a
# departure for a delivery nobody has bought.
#
# The lead itself is NOT stored. It is derivable — `slot_at - dispatch_at` —
# and a stored copy is a second place for it to be wrong after a reschedule.
class AddDispatchAtToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :dispatch_at, :timestamptz
  end
end
