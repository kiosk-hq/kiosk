# frozen_string_literal: true
zone = appointment.salon.zone
json.slot SalonClock.publish(appointment.slot, zone)
json.timezone zone.name
