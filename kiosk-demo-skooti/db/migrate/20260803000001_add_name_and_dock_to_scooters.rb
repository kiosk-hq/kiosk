# frozen_string_literal: true

# Demo-specific: give each fleet vehicle a human-readable name and a named
# pickup dock/location, so a plain prompt like "rent an electric scooter near
# Kadıköy" or "rent the Bosphorus Cruiser motorcycle" resolves to a concrete
# row. Without these, the fleet was anonymous ("scooter"/"motorcycle") and a
# rental prompt had no obvious target.
#
#   name — the vehicle's display name (e.g. "Bosphorus Cruiser").
#   dock — the named pickup point (e.g. "Kadıköy Dock", "Beşiktaş Pier").
#
# The `scooters_available` query returns both so an assistant can pick a
# vehicle by name or nearest dock before it commits to a rental verb.
class AddNameAndDockToScooters < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :scooters, :name, :string
    add_column :scooters, :dock, :string
  end
end
