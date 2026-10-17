# frozen_string_literal: true
json.array! @properties do |property|
  json.property_id property.id
  json.extract! property, :name, :city
end
