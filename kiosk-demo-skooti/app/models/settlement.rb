# frozen_string_literal: true

# A capture receipt kiosk-server wrote after a successful `pay`. skooti reads
# it for the payment gate both rental verbs share (start_rental's Gate 2,
# rent_motorcycle's Gate 3) and never writes one.
class Settlement < ApplicationRecord
  self.table_name = "kiosk.settlements"

  belongs_to :cart_mandate, inverse_of: :settlements

  # The same identity predicate {Reservation.owned_by_current_principal} uses,
  # on the engine's own table: the payer must be the principal the wire
  # resolved, read from the transaction GUC rather than from Ruby, so the
  # app-layer assertion and an RLS policy stay the same expression. Frozen
  # literal, no caller value.
  scope :of_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }
end
