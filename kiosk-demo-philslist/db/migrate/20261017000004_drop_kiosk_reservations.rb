# frozen_string_literal: true

# Drops kiosk.reservations. Nothing reads or writes it.
class DropKioskReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute 'DROP TABLE IF EXISTS "kiosk".reservations'
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
