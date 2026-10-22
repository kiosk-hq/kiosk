# frozen_string_literal: true

# Each assistant's tolled calls since its last paid proof: the reputation
# policy asks a proof when the count reaches its interval.
class AddCallsSinceProofToKioskAgents < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(ALTER TABLE "kiosk".agents ADD COLUMN calls_since_proof bigint NOT NULL DEFAULT 0)
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN calls_since_proof)
  end
end
