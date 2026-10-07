# frozen_string_literal: true

require "active_record"

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # The principal → Stripe Customer mapping, one row per principal, in the
      # host's `stripe_customers` table. The adapter's default resolver and saver.
      class CustomerRecord < ::ActiveRecord::Base
        self.table_name = "stripe_customers"

        # The table, from a host migration's `change`:
        #   def change = Kiosk::PaymentProviders::Stripe::CustomerRecord.create_table(self)
        def self.create_table(migration)
          migration.create_table :stripe_customers do |t|
            t.column :user_id,     :uuid, null: false
            t.string :customer_id, null: false
            t.timestamps
          end
          migration.add_index :stripe_customers, :user_id, unique: true
        end

        def self.resolve(user_id) = find_by(user_id: user_id)&.customer_id

        def self.save(user_id, customer_id)
          find_or_initialize_by(user_id: user_id).update!(customer_id: customer_id)
        end
      end
    end
  end
end
