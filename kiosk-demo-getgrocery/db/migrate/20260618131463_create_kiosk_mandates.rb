# frozen_string_literal: true

# Migration 006 — kiosk AP2 mandate trail:
# intent_mandates, cart_mandates, payment_mandates.
# See implementation-plan §3 and design-spec §5.
class CreateKioskMandates < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.mandates_sql(
      schema:       "kiosk",
      user_id_type: :uuid,
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".payment_mandates)
    execute %(DROP TABLE IF EXISTS "kiosk".settlements)
    execute %(DROP TABLE IF EXISTS "kiosk".cart_mandates)
    execute %(DROP TABLE IF EXISTS "kiosk".intent_mandates)
  end
end
