# frozen_string_literal: true

# Each order line keeps the price it was ordered at, so a catalogue change
# never reprices an order. Lines placed before this keep today's price.
class AddPriceCentsToOrderItems < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :order_items, :price_cents, :integer
    up_only do
      execute 'UPDATE order_items SET price_cents = products.price_cents FROM products ' \
              'WHERE products.id = order_items.product_id'
    end
    change_column_null :order_items, :price_cents, false
  end
end
