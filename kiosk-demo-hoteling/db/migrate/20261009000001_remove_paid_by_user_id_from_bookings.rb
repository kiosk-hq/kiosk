# frozen_string_literal: true

class RemovePaidByUserIdFromBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :bookings, :paid_by_user_id, :uuid
  end
end
