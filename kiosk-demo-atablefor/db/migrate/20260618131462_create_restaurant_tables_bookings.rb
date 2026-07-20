# frozen_string_literal: true

# Demo-specific schema: a food-delivery-shape provider (foodelivery per Plan 3).
#
# `restaurants` and `menu_items` are open-read (any authenticated principal browses).
# `orders` is owner-scoped via the place_order Action's explicit user_id scoping.
class CreateRestaurantsMenuOrders < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :restaurants do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :menu_items do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string  :name,        null: false
      t.string  :sku,         null: false
      t.integer :price_cents, null: false
      t.timestamps
    end

    create_table :orders, id: :uuid do |t|
      t.references :user,             null: false, foreign_key: true, type: :uuid
      t.references :restaurant,       null: false, foreign_key: true
      t.references :menu_item,        null: false, foreign_key: true
      t.integer    :quantity,         null: false, default: 1
      t.integer    :total_cents,      null: false
      t.string     :delivery_address, null: false
      t.string     :status,           null: false, default: "placed"
      t.timestamps
    end

    # Path C — RLS is dropped from the demo. Isolation is app-layer via the
    # place_order Action's explicit `user_id = kiosk.current_user_id()` scoping
    # and the `my_orders` query's own WHERE predicate. No DB-level row security needed.
  end
end
