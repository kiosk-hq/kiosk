# frozen_string_literal: true

# The AP2 cart mandate kiosk-server persists when it settles a payment — the
# signed list of line items the assistant agreed to pay for. hoteling reads it
# for ONE thing: `confirm_booking`'s Gate 2, "is there a settled cart that
# references THIS booking".
#
# An engine-owned table with no engine-owned reader, like {RoomHold} — see that
# class for why a demo models it rather than keeping the last SELECT string.
class CartMandate < ApplicationRecord
  self.table_name = "kiosk.cart_mandates"

  has_many :settlements, dependent: nil, inverse_of: :cart_mandate

  # Carts whose line_items contain an entry naming this booking. jsonb
  # containment, so the entry may carry sku/qty/price_cents alongside — the
  # booking reference is what is asserted.
  #
  # `booking_id` is CALLER-SUPPLIED, so it is a QUOTED node the adapter escapes
  # rather than an interpolated fragment. It has already passed {UuidCheck} by
  # the time it gets here; the quoting is what makes that a defence in depth
  # rather than the only defence.
  scope :referencing, lambda { |booking_id|
    where(Arel::Nodes::InfixOperation.new(
      "@>", arel_table[:line_items],
      Arel::Nodes.build_quoted([{ booking_id: booking_id.to_s }].to_json),
    ))
  }
end
