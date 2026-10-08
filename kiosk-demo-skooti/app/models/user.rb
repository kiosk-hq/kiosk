# frozen_string_literal: true

# A human rider, who signs in with a password, or an assistant account, which
# has no credentials and authenticates with its key only.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :reservations, dependent: :destroy
end
