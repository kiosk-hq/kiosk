# frozen_string_literal: true

class RemoveStatusFromScooters < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :scooters, :status, :string, null: false, default: 'available'
  end
end
