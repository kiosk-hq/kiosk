# frozen_string_literal: true

# kiosk-server keeps the verifications `request_kyc` opens in
# `kiosk.kyc_requests`; this app's own table is no longer read.
class DropKycVerificationRequests < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    drop_table :kyc_verification_requests
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
