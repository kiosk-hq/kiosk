# frozen_string_literal: true

class RemoveDepositFromRestaurantTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :restaurant_tables, :deposit_eur, :integer, null: false, default: 0
  end
end
