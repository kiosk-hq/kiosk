# frozen_string_literal: true

# What the shop owes the shopper's account for lines the shelf could not fill
# when the payment processor refused to return their price to the card.
class AddCreditedCentsToOrders < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :orders, :credited_cents, :integer, null: false, default: 0
  end
end
