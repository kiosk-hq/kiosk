# frozen_string_literal: true

# Add kyc_attributes jsonb to kiosk.agents. The NAMED ANONYMIZED boolean
# attributes a valid, broker-signed KYC attestation granted — for getgrocery,
# {"age_over_18": true}. Only the booleans are stored — never the DOB or any
# underlying document. The alcohol age-gate in create_order reads
# `kyc_attributes ->> 'age_over_18'`. Idempotent: ADD COLUMN IF NOT EXISTS.
class AddKycAttributes < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_attributes_sql(schema: "kiosk")
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS kyc_attributes)
  end
end
