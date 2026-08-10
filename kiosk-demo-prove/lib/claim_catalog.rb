# frozen_string_literal: true

# ClaimCatalog — the anonymized facts prove.my knows how to confirm, and how
# each maps to (a) a human-legible yes/no question on the verification page and
# (b) the boolean attribute name the minted claim carries (the name the
# operator's gate reads, e.g. rent_motorcycle checks age_over_18 + licence_a).
#
# The broker is a SHARED issuer (design §1.1): skooti asks for
# ["age_over_18","licence_category:A"]; a future alcohol demo would ask for
# ["age_over_18"] only; a betting demo ["age_over_21"]. Each operator asks for
# exactly the claims it needs; the catalog is the union the broker can answer.
module ClaimCatalog
  # request-claim id → { attribute:, question: }
  #   attribute — the boolean name minted into the claim's `attributes`.
  #   question  — the human-facing yes/no line on the verification page.
  ENTRIES = {
    "age_over_18" => {
      attribute: "age_over_18",
      question:  "I hereby confirm I am over 18 years old.",
    },
    # DELIBERATE EXTENSION POINT (K-599): no shipped operator requests
    # `age_over_21`. It is the executable half of the betting-demo example
    # above — proof that the catalog is a superset each operator draws a subset
    # from, and that teaching the broker a new fact is one entry. The request
    # spec drives it end to end, so it is covered surface, not dead surface.
    "age_over_21" => {
      attribute: "age_over_21",
      question:  "I hereby confirm I am over 21 years old.",
    },
    "licence_category:A" => {
      attribute: "licence_a",
      question:  "I hold a valid driving licence of category A (motorcycle).",
    },
  }.freeze

  module_function

  # The catalog entries for the requested claim ids, in request order. Unknown
  # ids are dropped (the broker cannot answer what it doesn't know).
  def entries_for(requested_claims)
    Array(requested_claims).filter_map { |id| ENTRIES[id.to_s] }
  end

  # Given the requested claims, the {attribute => true} hash the broker mints on
  # approve. Only the claims the operator actually asked for are granted.
  def attributes_for(requested_claims)
    entries_for(requested_claims).each_with_object({}) do |entry, acc|
      acc[entry[:attribute]] = true
    end
  end

  # True when every requested claim id is one the broker can answer.
  def all_known?(requested_claims)
    reqs = Array(requested_claims).map(&:to_s)
    !reqs.empty? && reqs.all? { |id| ENTRIES.key?(id) }
  end
end
