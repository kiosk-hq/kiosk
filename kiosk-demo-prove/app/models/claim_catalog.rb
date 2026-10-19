# frozen_string_literal: true

# The facts the broker can confirm, each the boolean attribute an approval
# grants. Each operator asks for the subset it gates on.
module ClaimCatalog
  # The facts the human confirms by ticking a box.
  QUESTIONS = { 'age_over_18' => 'I hereby confirm I am over 18 years old.' }.freeze

  # The driving-licence categories the human chooses from, each with the
  # categories a licence of it lets its holder ride. A real licence lists them.
  LICENCE_CATEGORIES = { 'A1' => %w[A1], 'A' => %w[A1 A], 'B1' => %w[B1], 'B' => %w[B], 'none' => [] }.freeze

  module_function

  # The attribute for riding `category`: `licence_a1` for A1.
  def licence_attribute(category) = "licence_#{category.downcase}"

  def licence_attributes = LICENCE_CATEGORIES.values.flatten.uniq.map { licence_attribute(it) }

  def known = QUESTIONS.keys + licence_attributes

  def questions_for(requested_claims) = QUESTIONS.values_at(*Array(requested_claims).map(&:to_s)).compact

  def asks_licence?(requested_claims) = Array(requested_claims).map(&:to_s).intersect?(licence_attributes)

  # The requested attributes that a human with a licence of `licence_category` holds.
  def attributes_for(requested_claims, licence_category)
    covered = LICENCE_CATEGORIES.fetch(licence_category.to_s, []).map { licence_attribute(it) }
    Array(requested_claims).map(&:to_s).select { QUESTIONS.key?(it) || covered.include?(it) }.index_with(true)
  end

  def all_known?(requested_claims)
    requested = Array(requested_claims).map(&:to_s)
    requested.any? && (requested - known).empty?
  end
end
