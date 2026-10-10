# frozen_string_literal: true

# Holds one vehicle, any kind, for the principal and quotes the upfront minute
# the cart must pay. Whether the principal may ride it is the rental verb's question.
class ReserveOperation
  def self.call(principal_id:, scooter_code:)
    reservation = Reservation.create!(user_id: principal_id, scooter_code: scooter_code)
    scooter     = reservation.scooter
    price       = scooter.price_per_min_cents

    {
      reservation_id:      reservation.id,
      scooter_code:        scooter.code,
      price_per_min_cents: price,
      currency:            "eur",
      pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == " \
                           "#{price} (the quoted upfront minute) and whose line_items " \
                           "reference this reservation: one {\"qty\": 1, \"price_cents\": " \
                           "#{price}, \"reservation_id\": \"#{reservation.id}\"} entry — " \
                           "the operator verifies currency and total against its quote before charging",
    }
  end
end
