# frozen_string_literal: true

# Migration 007 — add kyc_verified_at timestamptz to kiosk.agents.
# A non-NULL value means the agent has passed KYC attestation.
# Idempotent: ADD COLUMN IF NOT EXISTS — safe to re-run.
class AddKycVerifiedAt < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_verified_at_sql(schema: "kiosk")
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS kyc_verified_at)
  end
end
