# frozen_string_literal: true

# Migration 010 — create kiosk.auth_challenges.
# Each public key's outstanding auth challenge, so a challenge issued by one
# process is redeemed by any other (AuthChallengeStores::ActiveRecord, the default).
class CreateKioskAuthChallenges < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".auth_challenges (
        public_key text        PRIMARY KEY,
        nonce      text        NOT NULL,
        expires_at timestamptz NOT NULL
      );
      -- Supports the TTL sweep only.
      CREATE INDEX IF NOT EXISTS idx_auth_challenges_expires_at
        ON "kiosk".auth_challenges (expires_at);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".auth_challenges)
  end
end
