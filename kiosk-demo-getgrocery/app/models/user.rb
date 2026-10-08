# frozen_string_literal: true

# Human shoppers sign in with a password; an assistant's account is a row with
# no credentials, reachable only through its Kiosk key.
class User < ApplicationRecord
  devise :database_authenticatable
end
