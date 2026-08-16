# frozen_string_literal: true

# The AP2 cart mandate kiosk-server persists when it settles a payment — the
# signed list of line items the assistant agreed to pay for. skooti reads it
# for ONE thing: "is there a settled cart that references THIS reservation",
# which is what stops paying for reservation A and starting rental B.
#
# An engine-owned table with no engine-owned reader, like {Settlement} and
# {Agent} — see {Agent} for why a demo models it rather than keeping the last
# SELECT string.
class CartMandate < ApplicationRecord
  self.table_name = "kiosk.cart_mandates"

  has_many :settlements, dependent: nil, inverse_of: :cart_mandate

  # Carts whose line_items contain an entry naming this reservation. jsonb
  # containment, so the entry may carry sku/qty/price_cents alongside — the
  # reservation reference is what is asserted.
  #
  # `reservation_id` is CALLER-SUPPLIED, so it is a QUOTED node the adapter
  # escapes rather than an interpolated fragment. It has already passed
  # {WireArguments.uuid} by the time it gets here; the quoting is what makes
  # that a defence in depth rather than the only defence. The `::jsonb` cast
  # the hand-written SQL carried is gone because Postgres resolves the untyped
  # literal to jsonb from the left operand.
  scope :referencing, lambda { |reservation_id|
    where(Arel::Nodes::InfixOperation.new(
      "@>", arel_table[:line_items],
      Arel::Nodes.build_quoted([{ reservation_id: reservation_id.to_s }].to_json),
    ))
  }
end
