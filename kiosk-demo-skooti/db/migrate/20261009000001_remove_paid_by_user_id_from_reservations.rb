# frozen_string_literal: true

class RemovePaidByUserIdFromReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :reservations, :paid_by_user_id, :uuid
  end
end
