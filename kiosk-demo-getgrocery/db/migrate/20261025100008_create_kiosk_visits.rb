# frozen_string_literal: true

# The visits the operator records as fulfilled (Kiosk::Visit.record!). Their
# value lowers the proof-of-work toll for a returning customer.
class CreateKioskVisits < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_visits, id: :uuid do |t|
      t.column :user_id, :uuid, null: false
      t.bigint :value_cents, null: false
      t.timestamptz :visited_at, null: false, default: -> { 'now()' }
      t.check_constraint 'value_cents >= 0', name: 'kiosk_visits_value_cents'
      t.index %i[user_id visited_at]
    end
  end
end
