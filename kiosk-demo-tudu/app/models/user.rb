# frozen_string_literal: true

require "digest"

# An account: a human who signs in with email and password, or an assistant's
# headless account with no credentials at all.
class User < ApplicationRecord
  devise :database_authenticatable, :registerable

  has_many :lists, foreign_key: :account_id, inverse_of: :account, dependent: :destroy
  has_many :memberships, foreign_key: :account_id, inverse_of: :account, dependent: :destroy

  # The name other members of a list see: the one the account chose, else a
  # pseudonym derived from its id. Never the email address, nor anything derived
  # from it.
  def self.public_name(display_name, account_id)
    display_name.to_s.strip.presence || "member-#{Digest::SHA256.hexdigest(account_id.to_s)[0, 12]}"
  end
end
