# frozen_string_literal: true

# A single-use, TTL'd, HASHED collaboration code — tudu's own app-layer
# primitive for agent→agent list sharing (the spec is silent on invites by
# design). An owner mints one via the `invite` action; only the SHA-256
# `code_digest` is stored, and the plaintext is returned ONCE and travels
# human-to-human. `accept_invite` looks it up by digest, rejects
# expired/redeemed, and stamps `redeemed_by_account_id` + `redeemed_at`.
class Invite < ApplicationRecord
  belongs_to :list

  # Same hygiene the kiosk-server LinkCode uses: hash a strong random secret,
  # store only the digest, hand the plaintext over once.
  def self.digest(code)
    require "digest"
    Digest::SHA256.hexdigest(code.to_s)
  end
end
