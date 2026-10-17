# frozen_string_literal: true

# Migration 010 — create kiosk.auth_challenges.
# Each public key's outstanding auth challenge, so a challenge issued by one
# process is redeemed by any other (AuthChallengeStores::ActiveRecord, the default).
class CreateKioskAuthChallenges < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.auth_challenge_sql(
      schema: "kiosk",
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".auth_challenges)
  end
end
