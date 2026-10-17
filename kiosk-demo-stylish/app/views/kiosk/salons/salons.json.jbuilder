# frozen_string_literal: true
json.array! @salons do |salon|
  json.salon_id salon.id
  json.extract! salon, :name, :timezone
end
