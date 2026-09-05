# frozen_string_literal: true

# The AP2 cart mandate kiosk-server persists when it settles a payment — the
# signed list of line items the assistant agreed to pay for. getgrocery reads it
# for ONE thing: "does a settled cart reference THIS order", which is what makes
# "already paid" answerable at all.
#
# An engine-owned table with no engine-owned reader, the {Settlement} / {Agent}
# shape: kiosk-server writes the row, and this demo's order verbs, pay-path
# decorator and back office read it. Promoting it into the engine is a
# public-API decision, not a handler conversion.
class CartMandate < ApplicationRecord
  self.table_name = "kiosk.cart_mandates"

  has_many :settlements, dependent: nil, inverse_of: :cart_mandate

  # ── THE containment, bound to ONE named order ─────────────────────────────
  # Carts whose line_items contain an entry naming this order. jsonb
  # containment, so the entry may carry sku/qty/price_cents alongside — the
  # ORDER REFERENCE is what is asserted, and that is the whole of create_order's
  # `pay_hint` contract.
  #
  # `order_id` is CALLER-SUPPLIED, so it is a QUOTED node the adapter escapes
  # rather than an interpolated fragment. It has already passed
  # {WireArguments.order_id} by the time it gets here; the quoting is what makes
  # that a defence in depth rather than the only defence. No `::jsonb` cast is
  # needed on the right operand — Postgres resolves the untyped literal to jsonb
  # from the left one — but the CONTAINMENT OPERATOR must stay exactly what it
  # is: the replace guard and the pay race both rest on these semantics.
  #
  # The correlated form of the same predicate — "the cart references the order
  # row this SELECT is looking at", which has no caller value in it at all —
  # lives in {Order::SETTLED_CART_REFERENCES_THIS_ROW}, and the comment there
  # says why the two spellings both exist.
  scope :referencing, lambda { |order_id|
    where(Arel::Nodes::InfixOperation.new(
      "@>", arel_table[:line_items],
      Arel::Nodes.build_quoted([{ order_id: order_id.to_s }].to_json),
    ))
  }
end
