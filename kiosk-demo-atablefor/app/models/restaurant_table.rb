# frozen_string_literal: true

# A STATIC physical table at a restaurant: a named table with a seat capacity
# and an optional (display-only) no-show deposit. It carries NO date — a table
# is offered for every upcoming seating (see app/models/seatings.rb) and reused across
# them; a confirmed booking on (table, seating_at) claims it for exactly that
# seating, so tonight's 19:00 hold leaves tomorrow's 19:00 open.
class RestaurantTable < ApplicationRecord
  belongs_to :restaurant
  has_many   :bookings, dependent: :restrict_with_exception
end
