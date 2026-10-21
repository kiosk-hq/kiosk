# frozen_string_literal: true

# Drops kiosk.auth_challenges from a database that has it: the engine reads
# no such table. An assistant proves its key with a client assertion.
class DropKioskAuthChallenges < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(DROP TABLE IF EXISTS "kiosk".auth_challenges)
  end

  def down
    execute <<~'SQL'
      CREATE TABLE "kiosk".auth_challenges (
        public_key text        PRIMARY KEY,
        nonce      text        NOT NULL,
        expires_at timestamptz NOT NULL
      );
      CREATE INDEX idx_auth_challenges_expires_at ON "kiosk".auth_challenges (expires_at);
    SQL
  end
end
