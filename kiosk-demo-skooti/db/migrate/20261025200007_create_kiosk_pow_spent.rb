# frozen_string_literal: true

# The spent ids of proof-of-work challenges and client assertions. The primary
# key accepts each id once, in every process and across deploys.
class CreateKioskPowSpent < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_pow_spent, id: :text do |t|
      # The expiry sweep reads it.
      t.timestamptz :expires_at, null: false, index: true
    end
  end
end
