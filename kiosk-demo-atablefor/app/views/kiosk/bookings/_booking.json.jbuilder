seating = booking.local_seating
json.booking_id booking.id
json.restaurant booking.restaurant.name
json.neighborhood booking.restaurant.neighborhood
json.table_label booking.restaurant_table.label
json.party_size booking.party_size
json.seating_label Restaurant.seating_label(seating)
json.seating_at seating.iso8601
json.status booking.status
