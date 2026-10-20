# frozen_string_literal: true

# The arguments of a delivery-slots search: an address, and a day on that
# address's clock.
class SlotSearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :delivery_address, :string
  attribute :date, :date

  validates :delivery_address, served_address: true
  validate :date_not_ended, if: :date

  def zone = DeliverySlots.zone_at(delivery_address)

  def district = DublinZones.check(delivery_address).district

  # The named day at the address, never before the soonest day the shop delivers.
  def day
    soonest = DeliverySlots.soonest_date(zone)
    date ? [date, soonest].max : soonest
  end

  private

  def date_not_ended
    return unless date < zone.today

    errors.add(:date, "#{date.iso8601} is in the past at the delivery address (#{zone.name}); " \
                      "the earliest day you can ask for is #{zone.today.iso8601}.")
  end
end
