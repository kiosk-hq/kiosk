# frozen_string_literal: true

# Service menu + per-appointment pricing (EUR).
#
# The salon offers a fixed menu of services, each with a price in euro cents
# (EUR is the demo's currency). An appointment references the service booked,
# and captures the price AT BOOKING TIME onto the appointment row (a menu price
# can change later; the booked price is what the calendar and revenue total
# report). This is what makes the `salon_calendar` role reveal tangible: the
# owner's whole-book view carries a real € revenue total summed from these
# per-appointment prices, while each stylist sees only their own priced chairs.
class AddServicesAndPrices < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :services do |t|
      t.string  :name,        null: false
      t.integer :price_cents, null: false # EUR cents
      t.timestamps
    end

    # The service booked, and the price captured at booking time (euro cents).
    add_reference :appointments, :service,
                  type: :bigint, null: true, foreign_key: true
    add_column :appointments, :price_cents, :integer # EUR cents, captured at booking
  end
end
