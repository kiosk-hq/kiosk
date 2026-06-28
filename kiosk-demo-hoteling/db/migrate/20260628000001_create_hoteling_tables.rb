# frozen_string_literal: true
class CreateHotelingTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :properties do |t|
      t.string :name, null: false
      t.string :city, null: false
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
      t.string  :status,      null: false, default: "reserved"
      t.timestamps
    end
  end
end
