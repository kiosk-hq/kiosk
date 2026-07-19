# frozen_string_literal: true

# Demo-specific: distinguish the licence-free electric scooter from a
# COMBUSTION-ENGINE motorcycle that requires a category-A licence and age ≥ 18.
#
#   kind          — 'scooter' (licence-free electric, the default) or
#                   'motorcycle' (combustion; renting it is KYC-gated).
#   needs_licence — true when renting the vehicle requires the KYC attributes
#                   (age_over_18 AND licence_a). Only 'motorcycle' rows set it.
#
# The `rent_motorcycle` Action reads `needs_licence` and gates on the calling
# agent's stored KYC attributes; the licence-free scooter path stays KYC-free.
class AddVehicleKindToScooters < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :scooters, :kind,          :string,  null: false, default: "scooter"
    add_column :scooters, :needs_licence, :boolean, null: false, default: false
  end
end
