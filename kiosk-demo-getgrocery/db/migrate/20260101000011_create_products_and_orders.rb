# frozen_string_literal: true

# A grocery shop: a catalogue of products, and orders delivered to a door in a
# published window.
class CreateProductsAndOrders < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :products do |t|
      t.string  :sku,         null: false, index: { unique: true } # what assistants name a product by
      t.string  :name,        null: false
      t.integer :price_cents, null: false
      t.integer :stock,       null: false, default: 0
      # A cart holding one needs the person's `age_over_18` attestation.
      t.boolean :age_restricted, null: false, default: false
      t.timestamps
    end

    create_table :orders, id: :uuid do |t|
      t.references  :user, null: false, foreign_key: true, type: :uuid
      t.string      :status,      null: false, default: "created"
      t.integer     :total_cents, null: false, default: 0
      t.timestamptz :slot_at
      t.text        :address
      # The zone of the district the address routes to, recorded by the verb
      # that writes the order. No default: an INSERT that names no clock fails.
      t.string      :timezone, null: false
      # When the courier sets off; NULL until the order is paid.
      t.timestamptz :dispatch_at
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
