# frozen_string_literal: true

json.array! [@identity] do |identity|
  json.account_id identity.user_id
  json.agent_id identity.agent_id
  json.display_name @account.public_name
end
