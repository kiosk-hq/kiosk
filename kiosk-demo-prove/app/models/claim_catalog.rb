# frozen_string_literal: true

# The facts the broker can confirm: the question the human answers, and the
# boolean attribute an approval grants. Each operator asks for the subset it gates on.
module ClaimCatalog
  ENTRIES = {
    "age_over_18"        => { attribute: "age_over_18", question: "I hereby confirm I am over 18 years old." },
    "licence_category:A" => { attribute: "licence_a",   question: "I hold a valid driving licence of category A (motorcycle)." },
  }.freeze

  module_function

  def entries_for(requested_claims) = Array(requested_claims).filter_map { ENTRIES[_1.to_s] }

  def attributes_for(requested_claims) = entries_for(requested_claims).to_h { [_1[:attribute], true] }

  def all_known?(requested_claims)
    requested = Array(requested_claims).map(&:to_s)
    requested.any? && requested.all? { ENTRIES.key?(_1) }
  end
end
