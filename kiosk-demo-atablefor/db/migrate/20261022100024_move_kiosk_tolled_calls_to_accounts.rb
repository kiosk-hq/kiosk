# frozen_string_literal: true

# Each account's tolled calls since its last paid proof, shared by the
# assistants bound to the account. An account starts with the sum of the
# counts its assistants had.
class MoveKioskTolledCallsToAccounts < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~SQL
      CREATE TABLE "kiosk".tolled_calls (
        user_id            uuid PRIMARY KEY REFERENCES "users"(id) ON DELETE CASCADE,
        calls_since_proof  bigint NOT NULL DEFAULT 0
      );
      INSERT INTO "kiosk".tolled_calls (user_id, calls_since_proof)
        SELECT user_id, sum(calls_since_proof) FROM "kiosk".agents GROUP BY user_id;
      ALTER TABLE "kiosk".agents DROP COLUMN calls_since_proof;
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE "kiosk".agents ADD COLUMN calls_since_proof bigint NOT NULL DEFAULT 0;
      DROP TABLE "kiosk".tolled_calls;
    SQL
  end
end
