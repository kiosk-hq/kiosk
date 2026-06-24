# frozen_string_literal: true

# Demo-specific schema: a food-delivery-shape provider (foodelivery per Plan 3).
#
# `restaurants` and `menu_items` are open-read (any authenticated principal browses).
# `orders` is owner-scoped — RLS keys off `kiosk.current_user_id()`.
#
# Note: RLS isolation across users is NOT verified in this e2e because
# satellite-mode role separation per spec §7.6 isn't shipped in
# kiosk-server yet. The runtime connection uses the migration-owning
# role, which bypasses RLS. The script asserts the wire path
# (Executor → SET LOCAL → SQL → result envelope), not RLS enforcement.
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

    # RLS via the kiosk-rls DSL. The DSL emits ENABLE ROW LEVEL SECURITY,
    # GRANTs to the configured app_role, declares policies, attaches the
    # mandatory comment.
    enable_rls_on :restaurants do
      policy :select, using: "TRUE"
      comment "Restaurant catalogue. Browse-only via the agent surface."
    end

    enable_rls_on :menu_items do
      policy :select, using: "TRUE"
      comment "Menu items. Browse-only via the agent surface."
    end

    enable_rls_on :orders do
      policy :select, using: "user_id = kiosk.current_user_id()"
      policy :insert, check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
      comment "Customer's orders. Visible to the user across all of their agents."
    end
  end
end
