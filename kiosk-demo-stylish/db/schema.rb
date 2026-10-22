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

ActiveRecord::Schema[8.1].define(version: 2026_10_22_100024) do
  create_schema "kiosk"

  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "public.appointments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "salon_id", null: false
    t.bigint "service_id"
    t.timestamptz "slot", null: false
    t.integer "price_cents"
    t.timestamptz "visit_recorded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["salon_id"], name: "index_appointments_on_salon_id"
    t.index ["service_id"], name: "index_appointments_on_service_id"
    t.index ["user_id"], name: "index_appointments_on_user_id"
  end

  create_table "public.salons", force: :cascade do |t|
    t.string "name", null: false
    t.string "timezone", default: "Europe/Paris", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "public.services", force: :cascade do |t|
    t.string "name", null: false
    t.integer "price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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

  create_table "public.solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "public.solid_queue_batches", force: :cascade do |t|
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

  create_table "public.solid_queue_blocked_executions", force: :cascade do |t|
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

  create_table "public.solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "public.solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "public.solid_queue_jobs", force: :cascade do |t|
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

  create_table "public.solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "public.solid_queue_processes", force: :cascade do |t|
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

  create_table "public.solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "public.solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "public.solid_queue_recurring_tasks", force: :cascade do |t|
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

  create_table "public.solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "public.solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "public.users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email"
    t.string "encrypted_password", default: "", null: false
    t.string "staff_role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "public.appointments", "public.salons"
  add_foreign_key "public.appointments", "public.services"
  add_foreign_key "public.appointments", "public.users"
  add_foreign_key "public.solid_queue_batch_executions", "public.solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_batch_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_blocked_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_claimed_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_failed_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_ready_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_recurring_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "public.solid_queue_scheduled_executions", "public.solid_queue_jobs", column: "job_id", on_delete: :cascade

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
    t.text "spending_cap_currency"
    t.index ["issuer", "public_key"], name: "idx_agents_issuer_public_key_live", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "idx_agents_user_id", where: "(revoked_at IS NULL)"
    t.check_constraint "(spending_cap_cents IS NULL) = (spending_cap_currency IS NULL)", name: "agents_spending_cap_currency_set"
    t.check_constraint "spending_cap_currency ~ '^[a-z]{3}$'::text", name: "agents_spending_cap_currency_check"
  end

  create_table "kiosk.checkout_mandates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "reference", null: false
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
    t.text "checkout_hash", null: false
    t.index ["user_id", "checkout_hash"], name: "idx_checkout_mandates_live_checkout", unique: true, where: "(declined_at IS NULL)"
    t.index ["user_id"], name: "idx_checkout_mandates_user_id"
    t.unique_constraint ["user_id", "reference"], name: "checkout_mandates_user_id_reference_key"
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
    t.index ["checkout_mandate_id"], name: "idx_payment_mandates_checkout"
    t.index ["user_id"], name: "idx_payment_mandates_user_id"
    t.unique_constraint ["user_id", "reference"], name: "payment_mandates_user_id_reference_key"
  end

  create_table "kiosk.pow_spent", id: :text, force: :cascade do |t|
    t.timestamptz "expires_at", null: false
    t.index ["expires_at"], name: "idx_pow_spent_expires_at"
  end

  create_table "kiosk.refunds", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "settlement_id", null: false
    t.text "psp_reference", null: false
    t.bigint "refunded_amount_cents", null: false
    t.timestamptz "refunded_at", null: false
    t.index ["settlement_id"], name: "idx_refunds_settlement_id"
    t.check_constraint "refunded_amount_cents > 0", name: "refunds_refunded_amount_cents_check"
    t.unique_constraint ["psp_reference"], name: "refunds_psp_reference_key"
  end

  create_table "kiosk.revocations", primary_key: "agent_id", id: :uuid, default: nil, force: :cascade do |t|
    t.timestamptz "revoked_before", null: false
  end

  create_table "kiosk.settlements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "checkout_mandate_id", null: false
    t.uuid "user_id", null: false
    t.uuid "agent_id", null: false
    t.text "issuer", null: false
    t.text "psp_reference", null: false
    t.bigint "settled_amount_cents", null: false
    t.text "currency", null: false
    t.timestamptz "settled_at", null: false
    t.text "network_confirmation_id"
    t.index ["checkout_mandate_id"], name: "idx_settlements_checkout"
    t.index ["user_id"], name: "idx_settlements_user_id"
    t.unique_constraint ["checkout_mandate_id"], name: "settlements_checkout_mandate_id_key"
  end

  create_table "kiosk.tolled_calls", primary_key: "user_id", id: :uuid, default: nil, force: :cascade do |t|
    t.bigint "calls_since_proof", default: 0, null: false
  end

  create_table "kiosk.visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "value_cents", null: false
    t.timestamptz "visited_at", default: -> { "now()" }, null: false
    t.index ["user_id", "visited_at"], name: "idx_visits_user_id"
    t.check_constraint "value_cents >= 0", name: "visits_value_cents_check"
  end

  add_foreign_key "kiosk.agent_mappings", "kiosk.agents", name: "agent_mappings_agent_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.agent_tokens", "kiosk.agents", name: "agent_tokens_agent_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.agents", "public.users", name: "agents_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.kyc_attributes", "public.users", name: "kyc_attributes_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.kyc_requests", "public.users", name: "kyc_requests_user_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.payment_mandates", "kiosk.checkout_mandates", name: "payment_mandates_checkout_mandate_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.refunds", "kiosk.settlements", name: "refunds_settlement_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.revocations", "kiosk.agents", name: "revocations_agent_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.settlements", "kiosk.checkout_mandates", name: "settlements_checkout_mandate_id_fkey", on_delete: :cascade
  add_foreign_key "kiosk.tolled_calls", "public.users", name: "tolled_calls_user_id_fkey", on_delete: :cascade
end
