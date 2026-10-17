# frozen_string_literal: true

class RemoveStartedAtFromReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :reservations, :started_at, :timestamptz
  end
end
