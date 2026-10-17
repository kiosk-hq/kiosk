# frozen_string_literal: true

# A hotel booking provider: properties, their room types, and bookings of a
# room type for a run of nights.
class CreatePropertiesAndBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension "btree_gist"

    create_table :properties do |t|
      t.string  :name,          null: false
      t.string  :city,          null: false
      t.string  :neighbourhood, index: true
      t.string  :address
      t.integer :stars,         null: false, default: 3, index: true
      t.jsonb   :amenities,     null: false, default: []
      # The zone the property serves in; one operator may list hotels in many.
      t.string  :timezone,      null: false, default: "Europe/Istanbul"
      t.timestamps
    end

    create_table :room_types do |t|
      t.references :property, null: false, foreign_key: true
      t.string  :name,                null: false
      t.integer :nightly_price_cents, null: false
      t.timestamps
    end

    create_table :bookings, id: :uuid do |t|
      t.references :user,      null: false, foreign_key: true, type: :uuid
      t.references :property,  null: false, foreign_key: true
      t.references :room_type, null: false, foreign_key: true
      t.date    :check_in,    null: false
      t.date    :check_out,   null: false
      t.integer :total_cents, null: false
      t.string  :status,      null: false, default: "reserved" # reserved | confirmed | cancelled
      t.string  :confirmation_code, index: { unique: true }
      # unpaid → paying → paid. `paying` is claimed atomically before the
      # capture, so a booking is never captured twice; the payer is recorded
      # with it because anyone may pay for a booking.
      t.string  :payment_status,  null: false, default: "unpaid"
      t.uuid    :paid_by_user_id
      # The property answers minutes after the money arrives; a decline is
      # refunded, and the refund's PSP reference is the receipt.
      t.datetime :decision_due_at
      t.datetime :refunded_at
      t.string   :refund_psp_reference
      t.timestamps

      # A room type is never sold twice for the same night.
      t.exclusion_constraint "room_type_id WITH =, daterange(check_in, check_out) WITH &&",
                             using: :gist, where: "status IN ('reserved', 'confirmed')",
                             name: "bookings_no_overlapping_room_nights"
    end
  end
end
