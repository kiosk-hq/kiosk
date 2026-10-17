json.array! @members do |membership|
  json.extract! membership, :account_id, :display_name, :role
end
