# frozen_string_literal: true

# A bookable table + time-slot at a restaurant: a specific table (with a
# seat capacity) offered on a given date at a given time. A booking claims
# one open slot for a party.
class TableSlot < ApplicationRecord
  belongs_to :restaurant
  has_many   :bookings, dependent: :restrict_with_exception
end
