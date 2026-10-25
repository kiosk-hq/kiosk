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

ActiveRecord::Schema[8.1].define(version: 2026_10_25_200014) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "kiosk_agents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "allowed_roles", default: [], null: false, array: true
    t.text "public_key"
    t.text "human_label"
    t.bigint "spending_cap_cents"
    t.text "spending_cap_currency"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.timestamptz "bound_at"
    t.timestamptz "revoked_at"
    t.text "issuer", null: false
    t.index ["issuer", "public_key"], name: "index_kiosk_agents_on_issuer_and_public_key", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "index_kiosk_agents_on_user_id", where: "(revoked_at IS NULL)"
    t.check_constraint "(spending_cap_cents IS NULL) = (spending_cap_currency IS NULL)", name: "kiosk_agents_spending_cap_currency_set"
    t.check_constraint "spending_cap_currency ~ '^[a-z]{3}$'::text", name: "kiosk_agents_spending_cap_currency_code"
  end

  create_table "kiosk_assistant_accounts", primary_key: "user_id", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "merged_into"
    t.timestamptz "merged_at"
    t.index ["merged_into"], name: "index_kiosk_assistant_accounts_on_merged_into", where: "(merged_into IS NOT NULL)"
  end

  create_table "kiosk_checkout_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "reference", null: false
    t.text "checkout_hash", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.jsonb "line_items", null: false
    t.bigint "total_amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "expires_at", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "sd_jwt", null: false
    t.timestamptz "declined_at"
    t.index ["user_id", "checkout_hash"], name: "index_kiosk_checkout_mandates_on_user_id_and_checkout_hash", unique: true, where: "(declined_at IS NULL)"
    t.index ["user_id", "reference"], name: "index_kiosk_checkout_mandates_on_user_id_and_reference", unique: true
  end

  create_table "kiosk_device_authorizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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
    t.index ["device_code_hash"], name: "index_kiosk_device_authorizations_on_device_code_hash", unique: true
    t.index ["expires_at"], name: "index_kiosk_device_authorizations_on_expires_at", where: "(status = ANY (ARRAY['pending'::text, 'approved'::text]))"
    t.index ["user_code_hash"], name: "index_kiosk_device_authorizations_on_user_code_hash", unique: true, where: "(status = 'pending'::text)"
    t.check_constraint "kind = ANY (ARRAY['claim'::text, 'link'::text])", name: "kiosk_device_authorizations_kind"
    t.check_constraint "status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'consumed'::text, 'expired'::text])", name: "kiosk_device_authorizations_status"
  end

  create_table "kiosk_events", force: :cascade do |t|
    t.text "identity_key", null: false
    t.text "topic", null: false
    t.text "subject"
    t.timestamptz "occurred_at", null: false
    t.jsonb "data", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["created_at"], name: "index_kiosk_events_on_created_at"
    t.index ["identity_key", "id"], name: "index_kiosk_events_on_identity_key_and_id"
  end

  create_table "kiosk_kyc_attributes", primary_key: ["user_id", "name"], force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "name", null: false
    t.timestamptz "granted_at", default: -> { "now()" }, null: false
  end

  create_table "kiosk_kyc_requests", id: :text, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "nonce", null: false
    t.timestamptz "approved_at"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["user_id", "created_at"], name: "index_kiosk_kyc_requests_on_user_id_and_created_at"
  end

  create_table "kiosk_payment_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "reference", null: false
    t.uuid "checkout_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "payment_instrument", null: false
    t.bigint "amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "expires_at"
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "sd_jwt", null: false
    t.index ["checkout_mandate_id"], name: "index_kiosk_payment_mandates_on_checkout_mandate_id"
    t.index ["user_id", "reference"], name: "index_kiosk_payment_mandates_on_user_id_and_reference", unique: true
  end

  create_table "kiosk_pow_spent", id: :text, force: :cascade do |t|
    t.timestamptz "expires_at", null: false
    t.index ["expires_at"], name: "index_kiosk_pow_spent_on_expires_at"
  end

  create_table "kiosk_refunds", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "settlement_id", null: false
    t.text "psp_reference", null: false
    t.bigint "refunded_amount_cents", null: false
    t.timestamptz "refunded_at", null: false
    t.index ["psp_reference"], name: "index_kiosk_refunds_on_psp_reference", unique: true
    t.index ["settlement_id"], name: "index_kiosk_refunds_on_settlement_id"
    t.check_constraint "refunded_amount_cents > 0", name: "kiosk_refunds_refunded_amount_cents"
  end

  create_table "kiosk_revocations", primary_key: "agent_id", id: :uuid, default: nil, force: :cascade do |t|
    t.timestamptz "revoked_before", null: false
  end

  create_table "kiosk_settlements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "checkout_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "psp_reference", null: false
    t.bigint "settled_amount_cents", null: false
    t.text "currency", null: false
    t.text "network_confirmation_id"
    t.timestamptz "settled_at", null: false
    t.index ["checkout_mandate_id"], name: "index_kiosk_settlements_on_checkout_mandate_id", unique: true
    t.index ["user_id"], name: "index_kiosk_settlements_on_user_id"
  end

  create_table "kiosk_stripe_customers", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "customer_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_kiosk_stripe_customers_on_user_id", unique: true
  end

  create_table "kiosk_tolled_calls", primary_key: "user_id", id: :uuid, default: nil, force: :cascade do |t|
    t.bigint "calls_since_proof", default: 0, null: false
  end

  create_table "kiosk_visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "value_cents", null: false
    t.timestamptz "visited_at", default: -> { "now()" }, null: false
    t.index ["user_id", "visited_at"], name: "index_kiosk_visits_on_user_id_and_visited_at"
    t.check_constraint "value_cents >= 0", name: "kiosk_visits_value_cents"
  end

  create_table "order_items", force: :cascade do |t|
    t.uuid "order_id", null: false
    t.bigint "product_id", null: false
    t.integer "qty", default: 1, null: false
    t.integer "price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "status", default: "placed", null: false
    t.string "payment_status", default: "unpaid", null: false
    t.integer "total_cents", default: 0, null: false
    t.integer "refunded_cents", default: 0, null: false
    t.integer "credited_cents", default: 0, null: false
    t.timestamptz "slot_at", null: false
    t.text "address", null: false
    t.string "timezone", null: false
    t.timestamptz "dispatch_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "products", force: :cascade do |t|
    t.string "sku", null: false
    t.string "name", null: false
    t.integer "price_cents", null: false
    t.integer "stock", default: 0, null: false
    t.boolean "age_restricted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email"
    t.string "encrypted_password", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "kiosk_agents", "users", on_delete: :cascade
  add_foreign_key "kiosk_assistant_accounts", "users", column: "merged_into", on_delete: :cascade
  add_foreign_key "kiosk_assistant_accounts", "users", on_delete: :cascade
  add_foreign_key "kiosk_kyc_attributes", "users", on_delete: :cascade
  add_foreign_key "kiosk_kyc_requests", "users", on_delete: :cascade
  add_foreign_key "kiosk_payment_mandates", "kiosk_checkout_mandates", column: "checkout_mandate_id", on_delete: :cascade
  add_foreign_key "kiosk_refunds", "kiosk_settlements", column: "settlement_id", on_delete: :cascade
  add_foreign_key "kiosk_revocations", "kiosk_agents", column: "agent_id", on_delete: :cascade
  add_foreign_key "kiosk_settlements", "kiosk_checkout_mandates", column: "checkout_mandate_id", on_delete: :cascade
  add_foreign_key "kiosk_tolled_calls", "users", on_delete: :cascade
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "users"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
