# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon, optional: true
  # A bare salon booking names no service and captures no price.
  belongs_to :service, optional: true

  validate :salon_exists, :service_on_menu, :slot_ahead, on: :create

  before_create { self.price_cents = service&.price_cents }

  private

  def salon_exists
    return if salon

    errors.add(:salon_id, "#{salon_id.inspect} is not a salon here — call the `salons` query for the bookable salons")
  end

  def service_on_menu
    return if service_id.nil? || service

    menu = Service.order(:id).pluck(:id, :name).map { |id, name| "#{id} (#{name})" }.join(", ")
    errors.add(:service_id, "#{service_id.inspect} is not on the menu — bookable services: #{menu}; " \
                            "or omit service_id for a bare salon booking")
  end

  def slot_ahead
    return if salon.nil? || slot.nil? || slot.future?

    errors.add(:slot, "#{SalonClock.publish(slot, salon.zone)} has already passed — book a time in the future " \
                      "(now is #{SalonClock.publish(Time.current, salon.zone)}); this salon does not record " \
                      "appointments in the past")
  end
end
