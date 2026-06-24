# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_18_131462) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "menu_items", comment: "Menu items. Browse-only via the agent surface.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "price_cents", null: false
    t.bigint "restaurant_id", null: false
    t.string "sku", null: false
    t.datetime "updated_at", null: false
    t.index ["restaurant_id"], name: "index_menu_items_on_restaurant_id"
  end

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, comment: "Customer's orders. Visible to the user across all of their agents.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "delivery_address", null: false
    t.bigint "menu_item_id", null: false
    t.integer "quantity", default: 1, null: false
    t.bigint "restaurant_id", null: false
    t.string "status", default: "placed", null: false
    t.integer "total_cents", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["menu_item_id"], name: "index_orders_on_menu_item_id"
    t.index ["restaurant_id"], name: "index_orders_on_restaurant_id"
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "restaurants", comment: "Restaurant catalogue. Browse-only via the agent surface.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "menu_items", "restaurants"
  add_foreign_key "orders", "menu_items"
  add_foreign_key "orders", "restaurants"
  add_foreign_key "orders", "users"
end
