# frozen_string_literal: true

# One catalogue line. The wire references a product by its stable `sku` and
# never by the numeric primary key: that key is not a param of any verb, so
# publishing it would be a dead field an assistant can only guess at.
class Product < ApplicationRecord
  # Stock at or below this earns the `low` flag on a catalog row. It used to be
  # a top-level constant in the initializer, next to the handler that read it;
  # it belongs to the thing it is a fact about.
  LOW_STOCK_THRESHOLD = 5

  # What `catalog` publishes. Out-of-stock lines are HIDDEN rather than marked —
  # the assistant is choosing what to put in a basket, and a row it cannot buy
  # is an invitation to try.
  scope :in_stock, -> { where(arel_table[:stock].gt(0)) }

  # Integer EUR cents formatted for display, e.g. "€3" / "€17.75".
  # The wire stays canonical integer cents; this is an additive display field
  # so an assistant renders euros rather than raw cents or a guessed glyph.
  def self.format_eur(cents)
    cents = cents.to_i
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end

  def self.low_stock?(stock) = stock.to_i <= LOW_STOCK_THRESHOLD

  # ── THE age-gate predicate, in the ONE place both readings of the column
  # happen ───────────────────────────────────────────────────────────────────
  #
  # Two surfaces read `age_restricted` and they must not be able to drift: the
  # catalog ADVERTISES the 18+ gate on a row so an assistant knows to attest
  # before it orders, and `create_order` ENFORCES it. Advertising a row as
  # unrestricted that the gate then refuses is a wasted round trip; the reverse
  # — enforcing on a row the catalog never flagged — is worse.
  #
  # FAIL-CLOSED BY CONSTRUCTION. Enumerating the truthy spellings by hand
  # (`== true || == "t" || == "true"`) is correct against today's pg adapter and
  # fails OPEN against any other: one adapter, cast or schema change yielding
  # "TRUE" or 1, and the unrecognised value is treated as unrestricted — alcohol
  # sold past the age gate that exists to stop exactly that. So only a value
  # Rails recognises as literally FALSE (false, "f", "false", "0", 0, "") is
  # unrestricted; NULL, an unexpected spelling, or an `age_restricted` that
  # stopped being a boolean column is restricted, flagged in the catalog and
  # refused at the gate. On today's NOT NULL boolean column every reachable
  # value answers exactly as a hand-written list would.
  def self.age_restricted?(value)
    ActiveRecord::Type::Boolean.new.cast(value) != false
  end
end
