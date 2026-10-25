# frozen_string_literal: true

# Kiosk's identity tables: the registered assistants, the tolled calls of
# each account since its last paid proof, and the assistant accounts that
# registration opened, with the account each one merged into at its first binding.
class CreateKioskIdentityTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_agents, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade },
                          index: { where: 'revoked_at IS NULL' }
      t.text :allowed_roles, array: true, null: false, default: []
      t.text :public_key
      t.text :human_label
      # NULL: no cap. 0: no spending. A cap has its currency.
      t.bigint :spending_cap_cents
      t.text :spending_cap_currency
      t.timestamptz :created_at, null: false, default: -> { 'now()' }
      # The time of the latest binding.
      t.timestamptz :bound_at
      t.timestamptz :revoked_at
      t.text :issuer, null: false
      t.check_constraint "spending_cap_currency ~ '^[a-z]{3}$'", name: 'kiosk_agents_spending_cap_currency_code'
      t.check_constraint '(spending_cap_cents IS NULL) = (spending_cap_currency IS NULL)',
                         name: 'kiosk_agents_spending_cap_currency_set'
      # One live row per public key on an origin, enforced by the database; a revoked key can register again.
      t.index %i[issuer public_key], unique: true, where: 'revoked_at IS NULL'
    end

    create_table :kiosk_tolled_calls, primary_key: :user_id, id: :uuid, default: nil do |t|
      t.bigint :calls_since_proof, null: false, default: 0
      t.foreign_key :users, column: :user_id, on_delete: :cascade
    end

    create_table :kiosk_assistant_accounts, primary_key: :user_id, id: :uuid, default: nil do |t|
      t.column :merged_into, :uuid, index: { where: 'merged_into IS NOT NULL' }
      t.timestamptz :merged_at
      t.foreign_key :users, column: :user_id, on_delete: :cascade
      t.foreign_key :users, column: :merged_into, on_delete: :cascade
    end
  end
end
