# frozen_string_literal: true

# A spending cap has one currency, and a pay in another currency is refused.
# The demos charge only in euros, so an existing cap is a cap in euros.
class AddSpendingCapCurrencyToKioskAgents < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      ALTER TABLE "kiosk".agents
        ADD COLUMN spending_cap_currency text CHECK (spending_cap_currency ~ '^[a-z]{3}$');
      UPDATE "kiosk".agents SET spending_cap_currency = 'eur' WHERE spending_cap_cents IS NOT NULL;
      ALTER TABLE "kiosk".agents ADD CONSTRAINT agents_spending_cap_currency_set
        CHECK ((spending_cap_cents IS NULL) = (spending_cap_currency IS NULL));
    SQL
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN spending_cap_currency)
  end
end
