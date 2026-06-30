# frozen_string_literal: true

# Maps a synthetic principal (user_id) to a Stripe Customer ID on the
# provider's Stripe account. One row per principal, created lazily on the
# first `payment_setup` call that triggers SetupIntent. The mapping is
# injected into kiosk-pay-stripe via customer_resolver/customer_saver
# lambdas in config/initializers/kiosk.rb — the gem never touches this table.
class CreateStripeCustomers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :stripe_customers do |t|
      t.uuid   :user_id,     null: false
      t.string :customer_id, null: false
      t.timestamps
    end
    add_index :stripe_customers, :user_id, unique: true
  end
end
