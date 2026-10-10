# frozen_string_literal: true

# The stay a room list is asked for at one property: both dates, or neither for
# the property's full catalogue.
class RoomSearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :property
  attribute :check_in, :date
  attribute :check_out, :date

  validate :dates_together
  validates_with StayValidator

  def dated? = check_in.present? || check_out.present?

  # The property's room types, only those free for the stay when one is given.
  def room_types
    rooms = property.room_types
    dated? ? rooms.free_for(property.id, check_in, check_out) : rooms
  end

  private

  def dates_together
    return if check_in.present? == check_out.present?

    errors.add(:base, "check_in and check_out go together — pass both (YYYY-MM-DD) for a free-rooms " \
                      "list, or neither for the property's full catalogue")
  end
end
