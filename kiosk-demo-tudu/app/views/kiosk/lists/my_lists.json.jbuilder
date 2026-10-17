json.array! @lists do |list|
  json.list_id list.id
  json.extract! list, :title, :role
end
