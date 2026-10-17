# frozen_string_literal: true

# The principal → Stripe Customer mapping kiosk-pay-stripe reads and writes.
class CreateKioskPayStripeCustomers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change = Kiosk::PaymentProviders::Stripe::CustomerRecord.create_table(self)
end
