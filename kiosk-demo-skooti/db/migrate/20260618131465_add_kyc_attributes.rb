# frozen_string_literal: true

# Migration 009 — add kyc_attributes jsonb to kiosk.agents.
# The NAMED ANONYMIZED boolean attributes a valid KYC attestation granted
# (e.g. {"age_over_18": true, "licence_a": true}). Only the booleans are
# stored — never the DOB, licence number, or any underlying document.
# Idempotent: ADD COLUMN IF NOT EXISTS — safe to re-run.
class AddKycAttributes < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_attributes_sql(schema: "kiosk")
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS kyc_attributes)
  end
end
