json.array! [@identity] do |identity|
  json.account_id identity.user_id
  json.agent_id identity.agent_id
  json.display_name User.public_name(User.where(id: identity.user_id).pick(:display_name), identity.user_id)
end
