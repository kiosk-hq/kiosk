# frozen_string_literal: true

class CreateGetgroceryTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :products do |t|
      t.string  :name,        null: false
      t.integer :price_cents, null: false
      t.integer :stock,       null: false, default: 0
      t.timestamps
    end

    create_table :orders, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string     :status,      null: false, default: "created"  # created | paid | scheduled
      t.integer    :total_cents, null: false, default: 0
      t.timestamptz :slot_at,   null: true
      t.text        :address,   null: true
      t.timestamps
    end

    create_table :order_items do |t|
      t.references :order,   null: false, foreign_key: true, type: :uuid
      t.references :product, null: false, foreign_key: true
      t.integer    :qty,     null: false, default: 1
      t.timestamps
    end
  end
end
