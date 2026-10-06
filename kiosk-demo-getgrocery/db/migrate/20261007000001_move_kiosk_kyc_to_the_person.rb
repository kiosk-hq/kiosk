# frozen_string_literal: true

# The KYC grants move from the assistant account to the person, and
# `kiosk.kyc_requests` holds the verifications `request_kyc` opens. Grants
# already recorded are dropped, so people verify again. A fresh
# `kiosk:install` gets this shape from migration 006 and needs no separate file.
class MoveKioskKycToThePerson < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_on_person_sql(schema: "kiosk")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
