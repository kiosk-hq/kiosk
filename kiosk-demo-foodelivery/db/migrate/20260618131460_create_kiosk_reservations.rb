# frozen_string_literal: true

# Migration 004 — kiosk.reservations for atomic reserve-then-pay.
class CreateKioskReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.reservations_sql(
      schema:       "kiosk",
      user_id_type: :uuid,
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".reservations)
  end
end
