# frozen_string_literal: true

# A reservation holds its vehicle from `created_at` until `held_until`, and two
# holds of one vehicle never overlap. Reservations made before this hold nothing.
class AddHeldUntilToReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension 'btree_gist'
    add_column :reservations, :held_until, :datetime
    up_only { execute 'UPDATE reservations SET held_until = created_at' }
    change_column_null :reservations, :held_until, false
    add_exclusion_constraint :reservations, 'scooter_id WITH =, tsrange(created_at, held_until) WITH &&',
                             using: :gist, name: 'reservations_one_hold_per_scooter'
  end
end
