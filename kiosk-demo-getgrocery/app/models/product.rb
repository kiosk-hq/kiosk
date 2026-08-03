# frozen_string_literal: true
class Product < ApplicationRecord
  # Integer EUR cents formatted for display, e.g. "€3" / "€17.75".
  # The wire stays canonical integer cents; this is an additive display field
  # so an assistant renders euros rather than raw cents or a guessed glyph.
  def self.format_eur(cents)
    cents = cents.to_i
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end
end
