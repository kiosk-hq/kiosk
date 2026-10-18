# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon, optional: true
  # A bare salon booking names no service and captures no price.
  belongs_to :service, optional: true

  validate :salon_exists, :service_on_menu, :slot_ahead, on: :create

  before_create { self.price_cents = service&.price_cents }

  # Records the visit of an appointment whose slot has passed, worth its
  # service's price, once: the row lock makes two calls take turns, and the
  # second finds it stamped.
  def self.honour!(appointment_id)
    transaction do
      appointment = where(visit_recorded_at: nil, slot: ..Time.current).lock.find_by(id: appointment_id)
      next unless appointment

      appointment.update!(visit_recorded_at: Time.current)
      Kiosk::Visit.record!(user_id: appointment.user_id, value_cents: appointment.price_cents.to_i)
    end
  end

  private

  def salon_exists
    return if salon

    errors.add(:salon_id, "#{salon_id.inspect} is not a salon here; call `salons` for the list")
  end

  def service_on_menu
    return if service_id.nil? || service

    menu = Service.order(:id).pluck(:id, :name).map { |id, name| "#{id} (#{name})" }.join(', ')
    errors.add(:service_id, "#{service_id.inspect} is not on the menu (#{menu}); omit it to book the salon alone")
  end

  def slot_ahead
    return if salon.nil? || slot.nil? || slot.future?

    errors.add(:slot, "#{SalonClock.publish(slot, salon.zone)} has already passed; book a time after " \
                      "#{SalonClock.publish(Time.current, salon.zone)}")
  end
end
