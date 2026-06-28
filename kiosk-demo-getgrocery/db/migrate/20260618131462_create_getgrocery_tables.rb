# frozen_string_literal: true

class CreateGetgroceryTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :stores do |t|
      t.string :name, null: false
      t.string :city, null: false
      t.timestamps
    end

    create_table :products do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :sku,         null: false
      t.string  :name,        null: false
      t.integer :price_cents, null: false
      t.integer :stock,       null: false, default: 0
      t.timestamps
    end

    create_table :substitution_policies do |t|
      t.references :store,             null: false, foreign_key: true
      t.integer    :out_product_id,    null: false
      t.integer    :suggested_product_id, null: false
      t.timestamps
      t.index [:store_id, :out_product_id], unique: true
    end

    create_table :carts, id: :uuid do |t|
      t.references :user,  null: false, foreign_key: true, type: :uuid
      t.references :store, null: false, foreign_key: true
      t.string     :status, null: false, default: "open"
      t.timestamps
      t.index [:user_id, :store_id, :status]
    end

    create_table :cart_items do |t|
      t.references :cart,    null: false, foreign_key: true, type: :uuid
      t.references :product, null: false, foreign_key: true
      t.integer    :qty,         null: false, default: 1
      t.boolean    :substituted, null: false, default: false
      t.timestamps
    end

    create_table :deliveries, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :cart, null: false, foreign_key: true, type: :uuid
      t.timestamp  :slot_at,  null: false
      t.string     :address,  null: false
      t.string     :status,   null: false, default: "scheduled"
      t.timestamps
    end
  end
end
