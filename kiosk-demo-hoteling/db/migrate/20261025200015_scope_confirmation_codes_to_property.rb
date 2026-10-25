# frozen_string_literal: true

# A confirmation code is six digits, unique at its property: the front desk
# looks a guest up by the code among its own bookings.
class ScopeConfirmationCodesToProperty < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_index :bookings, :confirmation_code, unique: true
    add_index :bookings, %i[property_id confirmation_code], unique: true
  end
end
