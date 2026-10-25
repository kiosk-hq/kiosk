# frozen_string_literal: true

# The refunds of settled charges, one row per PSP refund. Recent spend counts
# a settlement less what was refunded of it.
class CreateKioskRefunds < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_refunds, id: :uuid do |t|
      t.references :settlement, type: :uuid, null: false,
                                foreign_key: { to_table: :kiosk_settlements, on_delete: :cascade }
      t.text :psp_reference, null: false, index: { unique: true }
      t.bigint :refunded_amount_cents, null: false
      t.timestamptz :refunded_at, null: false
      t.check_constraint 'refunded_amount_cents > 0', name: 'kiosk_refunds_refunded_amount_cents'
    end
  end
end
