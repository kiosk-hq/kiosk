# frozen_string_literal: true

# Holds one vehicle, any kind, for the customer and quotes the upfront minute
# the cart must pay. Whether the customer may ride it is the rental verb's question.
class ReserveOperation
  def self.call(customer_id:, scooter_code:)
    reservation = Reservation.create!(user_id: customer_id, scooter_code: scooter_code)
    price       = reservation.scooter.price_per_min_cents

    {
      reservation_id:      reservation.id,
      price_per_min_cents: price,
      currency:            "eur",
      pay_hint:            "sign a cart in eur with total_amount_cents #{price} and one line item " \
                           "{\"qty\": 1, \"price_cents\": #{price}, \"reservation_id\": \"#{reservation.id}\"}",
    }
  end
end
