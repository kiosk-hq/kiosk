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
  # service's price, once: only the call that stamps `visit_recorded_at` records it.
  def self.honour!(appointment_id)
    transaction do
      stamped = where(id: appointment_id, visit_recorded_at: nil, slot: ..Time.current)
                .update_all(visit_recorded_at: Time.current)
      next unless stamped == 1

      appointment = find(appointment_id)
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
