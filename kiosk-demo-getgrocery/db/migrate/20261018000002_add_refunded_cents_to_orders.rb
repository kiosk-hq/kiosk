# frozen_string_literal: true

# What went back to the card for lines a concurrent payment emptied the shelf of.
class AddRefundedCentsToOrders < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :orders, :refunded_cents, :integer, null: false, default: 0
  end
end
