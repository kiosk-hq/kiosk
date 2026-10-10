# frozen_string_literal: true

# The arguments of a delivery-slots search: an address, and the day the caller
# names on its own calendar (`Kiosk-Timezone`, else the address's).
class SlotSearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :delivery_address, :string
  attribute :date, :date
  attribute :caller_zone

  validates :delivery_address, served_address: true
  validate :date_not_ended, if: :date

  def zone = DeliverySlots.zone_at(delivery_address)

  def district = DublinZones.check(delivery_address).district

  # The shop's day the caller's day starts on, never before the soonest it delivers.
  def day
    soonest = DeliverySlots.soonest_date(zone)
    date ? [date.in_time_zone(calendar).in_time_zone(zone).to_date, soonest].max : soonest
  end

  private

  def calendar = caller_zone || zone

  # A day the caller is still in is answered even when the shop has rolled over.
  def date_not_ended
    return unless date.in_time_zone(calendar).tomorrow.past?

    errors.add(:date, "#{date.iso8601} is in the past on the calendar it is read in (#{calendar.name}); " \
                      "the earliest day you can ask for is #{calendar.today.iso8601}. The day is read in " \
                      "YOUR calendar when you declare Kiosk-Timezone, and in the delivery address's when " \
                      "you do not.")
  end
end
