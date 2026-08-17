# frozen_string_literal: true

# A capture receipt kiosk-server wrote after a successful `pay`. getgrocery
# reads it for the ONE question every paid-state answer on this origin rests
# on — "is there a settled cart that references THIS order" — and never writes
# one; the engine's executor does that, in the phase after the charge.
#
# Three surfaces ask that question and they do NOT ask it with the same
# authority, which is why this model exposes only the identity scope and leaves
# the containment to {CartMandate} and {Order}: `my_orders` asks it about the
# CALLER's settlements, `reschedule_delivery`'s payment gate likewise, and the
# operator's own back office asks it about ALL of them, because a back office
# that could only see its own rows would show nothing at all.
class Settlement < ApplicationRecord
  self.table_name = "kiosk.settlements"

  belongs_to :cart_mandate, inverse_of: :settlements

  # The same identity predicate {Order.owned_by_current_principal} uses, on the
  # engine's own table: the payer must be the principal the wire resolved, read
  # from the transaction GUC rather than from Ruby, so the app-layer assertion
  # and an RLS policy stay the same expression. Frozen literal, no caller value.
  scope :of_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }
end
