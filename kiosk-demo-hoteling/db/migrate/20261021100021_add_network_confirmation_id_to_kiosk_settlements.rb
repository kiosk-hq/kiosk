# frozen_string_literal: true

# The payment receipt that pay answers names the card network's id of the
# charge, when the payment provider reports one. A settlement keeps it, so a
# repeat of a settled pair answers the same receipt.
class AddNetworkConfirmationIdToKioskSettlements < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(ALTER TABLE "kiosk".settlements ADD COLUMN network_confirmation_id text)
  end

  def down
    execute %(ALTER TABLE "kiosk".settlements DROP COLUMN network_confirmation_id)
  end
end
