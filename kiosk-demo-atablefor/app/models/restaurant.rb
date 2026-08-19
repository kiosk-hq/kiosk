# frozen_string_literal: true

class Restaurant < ApplicationRecord
  has_many :restaurant_tables, dependent: :restrict_with_exception
  has_many :bookings,          dependent: :restrict_with_exception

  # The neighbourhoods this aggregator actually serves — the DB-derived closed
  # set `availability`'s `neighborhood` filter is checked against (T-090, spec
  # §9.1). It lives here rather than in the guard because it is a fact about
  # the restaurants, and because the SAME set has to be both what the refusal
  # NAMES and what the filter MATCHES: two spellings of it could disagree, and
  # then the verb would refuse a value it would have answered.
  #
  # `compact`: `neighborhood` is nullable, and a null is not a name a caller
  # could have passed.
  def self.served_neighborhoods
    distinct.order(:neighborhood).pluck(:neighborhood).compact
  end
end
