# frozen_string_literal: true

require "digest"

# A single-use collaboration code. Only its SHA-256 digest is stored; the
# plaintext is handed to the owner once.
class Invite < ApplicationRecord
  belongs_to :list

  scope :redeemable, -> { where(redeemed_at: nil, expires_at: Time.current..) }

  def self.digest(code) = Digest::SHA256.hexdigest(code.to_s)
end
