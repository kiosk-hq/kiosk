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

ActiveRecord::Schema[8.1].define(version: 2026_10_09_000002) do
  create_schema "kiosk"

  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "public.bookings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "property_id", null: false
    t.bigint "room_type_id", null: false
    t.date "check_in", null: false
    t.date "check_out", null: false
    t.integer "total_cents", null: false
    t.string "status", default: "reserved", null: false
    t.string "confirmation_code"
    t.string "payment_status", default: "unpaid", null: false
    t.datetime "decision_due_at"
    t.datetime "refunded_at"
    t.string "refund_psp_reference"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmation_code"], name: "index_bookings_on_confirmation_code", unique: true
    t.index ["property_id"], name: "index_bookings_on_property_id"
    t.index ["room_type_id"], name: "index_bookings_on_room_type_id"
    t.index ["user_id"], name: "index_bookings_on_user_id"
    t.exclusion_constraint "room_type_id WITH =, daterange(check_in, check_out) WITH &&", where: "(status)::text = ANY (ARRAY[('reserved'::character varying)::text, ('confirmed'::character varying)::text])", using: :gist, name: "bookings_no_overlapping_room_nights"
  end

  create_table "public.properties", force: :cascade do |t|
    t.string "name", null: false
    t.string "city", null: false
    t.string "neighbourhood"
    t.string "address"
    t.integer "stars", default: 3, null: false
    t.jsonb "amenities", default: [], null: false
    t.string "timezone", default: "Europe/Istanbul", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["neighbourhood"], name: "index_properties_on_neighbourhood"
    t.index ["stars"], name: "index_properties_on_stars"
  end

  create_table "public.room_types", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "name", null: false
    t.integer "nightly_price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_room_types_on_property_id"
  end

  create_table "public.solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "public.stripe_customers", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "customer_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_stripe_customers_on_user_id", unique: true
  end

  create_table "public.users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email"
    t.string "encrypted_password", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "public.bookings", "public.properties"
  add_foreign_key "public.bookings", "public.room_types"
  add_foreign_key "public.bookings", "public.users"
  add_foreign_key "public.room_types", "public.properties"

  create_table "kiosk.agent_mappings", primary_key: ["provider", "external_id"], force: :cascade do |t|
    t.text "provider", null: false
    t.text "external_id", null: false
    t.uuid "agent_id", null: false
  end

  create_table "kiosk.agent_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.text "token_hash", null: false
    t.timestamptz "issued_at", default: -> { "now()" }, null: false
    t.timestamptz "expires_at", null: false
    t.timestamptz "revoked_at"
    t.index ["agent_id"], name: "idx_agent_tokens_agent_id"
    t.index ["token_hash"], name: "idx_agent_tokens_hash", unique: true
  end

  create_table "kiosk.agents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "allowed_roles", default: [], null: false, array: true
    t.text "public_key"
    t.text "human_label"
    t.bigint "spending_cap_cents"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.timestamptz "revoked_at"
    t.text "issuer", null: false
    t.index ["issuer", "public_key"], name: "idx_agents_issuer_public_key_live", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "idx_agents_user_id", where: "(revoked_at IS NULL)"
  end

  create_table "kiosk.cart_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "mandate_id", null: false
    t.uuid "intent_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.jsonb "line_items", null: false
    t.bigint "total_amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "expires_at", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "raw_jws", null: false
    t.index ["intent_mandate_id"], name: "idx_cart_mandates_intent"
    t.index ["user_id"], name: "idx_cart_mandates_user_id"
    t.unique_constraint ["user_id", "mandate_id"], name: "cart_mandates_user_id_mandate_id_key"
  end

  create_table "kiosk.device_authorizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "device_code_hash", null: false
    t.text "user_code_hash", null: false
    t.text "public_key_pem"
    t.text "kind", default: "claim", null: false
    t.text "client_id", null: false
    t.text "requested_role"
    t.text "status", null: false
    t.uuid "user_id"
    t.timestamptz "expires_at", null: false
    t.timestamptz "consumed_at"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["device_code_hash"], name: "idx_device_authorizations_code_hash", unique: true
    t.index ["expires_at"], name: "idx_device_authorizations_expiry", where: "(status = ANY (ARRAY['pending'::text, 'approved'::text]))"
    t.index ["user_code_hash"], name: "idx_device_authorizations_user_code_pending", unique: true, where: "(status = 'pending'::text)"
    t.check_constraint "kind = ANY (ARRAY['claim'::text, 'link'::text])", name: "device_authorizations_kind_check"
    t.check_constraint "status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'consumed'::text, 'expired'::text])", name: "device_authorizations_status_check"
  end

  create_table "kiosk.events", force: :cascade do |t|
    t.text "identity_key", null: false
    t.text "topic", null: false
    t.text "subject"
    t.timestamptz "occurred_at", null: false
    t.jsonb "data", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["created_at"], name: "idx_events_created_at"
    t.index ["identity_key", "id"], name: "idx_events_identity_key_id"
  end

  create_table "kiosk.intent_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "scope", null: false
    t.bigint "cap_amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "expires_at", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "raw_jws", null: false
    t.index ["agent_id"], name: "idx_intent_mandates_agent_id"
    t.index ["user_id"], name: "idx_intent_mandates_user_id"
    t.unique_constraint ["user_id", "mandate_id"], name: "intent_mandates_user_id_mandate_id_key"
  end

  create_table "kiosk.kyc_attributes", primary_key: ["user_id", "name"], force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "name", null: false
    t.timestamptz "granted_at", default: -> { "now()" }, null: false
  end

  create_table "kiosk.kyc_requests", id: :text, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "nonce", null: false
    t.timestamptz "approved_at"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["user_id", "created_at"], name: "idx_kyc_requests_user_id"
  end

  create_table "kiosk.payment_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "mandate_id", null: false
    t.uuid "cart_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "payment_method", null: false
    t.bigint "amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "expires_at"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "raw_jws", null: false
    t.index ["cart_mandate_id"], name: "idx_payment_mandates_cart"
    t.index ["user_id"], name: "idx_payment_mandates_user_id"
    t.unique_constraint ["user_id", "mandate_id"], name: "payment_mandates_user_id_mandate_id_key"
  end

  create_table "kiosk.pow_spent", id: :text, force: :cascade do |t|
    t.timestamptz "expires_at", null: false
    t.index ["expires_at"], name: "idx_pow_spent_expires_at"
  end

  create_table "kiosk.reservations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "agent_id"
    t.text "resource_kind", null: false
    t.text "resource_id", null: false
    t.jsonb "args", default: {}, null: false
    t.timestamptz "reserved_at", default: -> { "now()" }, null: false
    t.timestamptz "expires_at", null: false
    t.timestamptz "released_at"
    t.index ["expires_at"], name: "idx_reservations_expiry", where: "(released_at IS NULL)"
    t.index ["user_id"], name: "idx_reservations_user_id"
    t.unique_constraint ["resource_kind", "resource_id", "released_at"], deferrable: :deferred, name: "reservations_unique_active"
  end

  create_table "kiosk.settlements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "cart_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "psp_reference", null: false
    t.bigint "settled_amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "settled_at", null: false
    t.index ["cart_mandate_id"], name: "idx_settlements_cart"
    t.index ["user_id"], name: "idx_settlements_user_id"
    t.unique_constraint ["cart_mandate_id"], name: "settlements_cart_mandate_id_key"
  end

  add_foreign_key "kiosk.agent_mappings", "kiosk.agents", name: "agent_mappings_agent_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.agent_tokens", "kiosk.agents", name: "agent_tokens_agent_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.agents", "public.users", name: "agents_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.cart_mandates", "kiosk.intent_mandates", name: "cart_mandates_intent_mandate_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.kyc_attributes", "public.users", name: "kyc_attributes_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.kyc_requests", "public.users", name: "kyc_requests_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.payment_mandates", "kiosk.cart_mandates", name: "payment_mandates_cart_mandate_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.settlements", "kiosk.cart_mandates", name: "settlements_cart_mandate_id_fkey", on_delete: :cascade
end
