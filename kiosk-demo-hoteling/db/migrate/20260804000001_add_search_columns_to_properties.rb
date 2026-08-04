# frozen_string_literal: true

# T-042 / K-452: give `properties` the columns a realistic multi-parameter
# hotel search filters on (neighbourhood, star rating, amenities, address) so
# the ~100-hotel search_hotels query is genuine, not cosmetic. Additive: existing
# rows/seeds keep working (nullable-with-default backfill on the two required-ish
# columns; neighbourhood/address are free-form and backfilled in seeds).
class AddSearchColumnsToProperties < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :properties, :neighbourhood, :string
    add_column :properties, :stars,         :integer, null: false, default: 3
    add_column :properties, :amenities,     :jsonb,   null: false, default: []
    add_column :properties, :address,       :string

    add_index :properties, :neighbourhood
    add_index :properties, :stars
  end
end
