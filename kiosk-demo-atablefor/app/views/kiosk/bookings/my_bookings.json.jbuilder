# frozen_string_literal: true

json.array! @bookings, partial: 'kiosk/bookings/booking', as: :booking
