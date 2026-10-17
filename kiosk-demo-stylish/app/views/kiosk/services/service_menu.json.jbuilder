json.array! @menu do |service|
  json.service_id service.id
  json.name service.name
  json.partial! 'price', service: service
end
