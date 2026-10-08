# frozen_string_literal: true

# A restaurant aggregator: many restaurants, each with named physical tables
# that are offered for every upcoming seating. A booking pins one table at one
# seating instant; the partial unique index lets only one confirmed booking
# claim a (table, seating), and a cancelled one frees it.
class CreateRestaurantsAndBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :restaurants do |t|
      t.string :name, null: false
      t.string :neighborhood
      t.string :cuisine
      # The zone the restaurant serves in; an aggregator lists places in many.
      t.string :timezone, null: false, default: "Europe/Lisbon"
      t.timestamps
    end

    create_table :restaurant_tables do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string  :label,       null: false
      t.integer :capacity,    null: false
      # A no-show hold shown in EUR and settled at the restaurant, never on the wire.
      t.integer :deposit_eur, null: false, default: 0
      t.timestamps
      t.index %i[restaurant_id label], unique: true
    end

    create_table :bookings, id: :uuid do |t|
      t.references :user,             null: false, foreign_key: true, type: :uuid
      t.references :restaurant,       null: false, foreign_key: true
      t.references :restaurant_table, foreign_key: true
      t.timestamptz :seating_at
      t.integer    :party_size, null: false
      t.string     :status,     null: false, default: "confirmed" # confirmed | cancelled
      t.timestamps
      t.index %i[restaurant_table_id seating_at], unique: true, where: "status = 'confirmed'",
                                                   name: "idx_bookings_confirmed_table_seating"
    end
  end
end
