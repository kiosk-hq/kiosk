# frozen_string_literal: true

# A person's KYC grants and verifications go when their user row does. Rows
# whose person is already gone are deleted. A fresh `kiosk:install` gets this
# key from migration 006 and needs no separate file.
class TieKioskKycToTheUser < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.kyc_user_fk_sql(schema: "kiosk")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
