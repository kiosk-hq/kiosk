# frozen_string_literal: true

# The principal → Stripe Customer mapping kiosk-pay-stripe reads and writes.
class CreateKioskPayStripeCustomers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :stripe_customers do |t|
      t.column :user_id, :uuid, null: false
      t.string :customer_id, null: false
      t.timestamps
    end
    add_index :stripe_customers, :user_id, unique: true
  end
end
