price = @reservation.scooter.price_per_min_cents
json.reservation_id @reservation.id
json.price_per_min_cents price
json.currency "eur"
json.pay_hint "sign a cart in eur with total_amount_cents #{price} and one line item " \
              "{\"qty\": 1, \"price_cents\": #{price}, \"reservation_id\": \"#{@reservation.id}\"}"
