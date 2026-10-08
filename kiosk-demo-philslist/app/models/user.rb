# frozen_string_literal: true

require "digest"

# The account principal. Human account holders sign in with email and
# password; assistant accounts have no credentials and authenticate by key.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :listings, foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy

  # The seller's name on the public board. Derived from the account UUID and
  # never from the email, because the board publishes it to every principal and
  # an email hash falls to a wordlist. One per seller, so a household's
  # listings read under one name.
  def self.public_handle(account_id)
    "seller-#{Digest::SHA256.hexdigest(account_id.to_s)[0, 12]}"
  end

  def public_handle = self.class.public_handle(id)
end
