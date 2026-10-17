json.array! @menu do |service|
  json.service_id service.id
  json.service service.name
  json.open true
  json.partial! "price", service: service
end
