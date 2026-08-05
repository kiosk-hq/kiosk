# frozen_string_literal: true

# Add kyc_verified_at timestamptz to kiosk.agents. A non-NULL value means the
# agent has passed a KYC attestation. getgrocery needs this (alongside
# kyc_attributes) so the shipped POST /kiosk/agents/kyc controller can stamp a
# broker-signed age_over_18 attestation, which the alcohol age-gate in
# create_order then reads. Idempotent: ADD COLUMN IF NOT EXISTS.
class AddKycVerifiedAt < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_verified_at_sql(schema: "kiosk")
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS kyc_verified_at)
  end
end
