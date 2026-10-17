# frozen_string_literal: true

json.array! @search.open_tables do |restaurant, table, seating|
  json.restaurant restaurant.name
  json.extract! restaurant, :neighborhood, :cuisine
  json.restaurant_table_id table.id
  json.table_label table.label
  json.capacity table.capacity
  json.seating_label Restaurant.seating_label(seating)
  json.seating_at seating.iso8601
end
