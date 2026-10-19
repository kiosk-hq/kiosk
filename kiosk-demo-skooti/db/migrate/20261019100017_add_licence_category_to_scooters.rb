# frozen_string_literal: true

# The driving-licence category a vehicle needs: A1 or A, or none for a scooter.
# Renting a vehicle that names one needs the rider's `age_over_18` and the
# licence attribute of that category, such as `licence_a1`.
class AddLicenceCategoryToScooters < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :scooters, :licence_category, :string
    up_only { execute "UPDATE scooters SET licence_category = 'A' WHERE kind = 'motorcycle'" }
  end
end
