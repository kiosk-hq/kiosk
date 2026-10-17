# frozen_string_literal: true

# An appointment's slot has come: it counts as a visit.
class AppointmentKeptJob < ApplicationJob
  queue_as :default

  def perform(appointment_id) = Appointment.honour!(appointment_id)
end
