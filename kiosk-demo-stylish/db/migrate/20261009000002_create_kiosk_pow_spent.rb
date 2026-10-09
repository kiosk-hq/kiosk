# frozen_string_literal: true

# Migration 008 — create kiosk.pow_spent.
# The spent proof-of-work challenge ids, so a proof is accepted once across
# every process and every deploy (PowSpentStores::ActiveRecord, the default).
class CreateKioskPowSpent < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.pow_spent_sql(
      schema: "kiosk",
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".pow_spent)
  end
end
