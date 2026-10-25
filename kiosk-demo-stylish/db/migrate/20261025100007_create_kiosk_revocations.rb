# frozen_string_literal: true

# Each agent's revocation watermark: a token issued before it stops verifying,
# in every process and after a restart.
class CreateKioskRevocations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_revocations, primary_key: :agent_id, id: :uuid, default: nil do |t|
      t.timestamptz :revoked_before, null: false
      t.foreign_key :kiosk_agents, column: :agent_id, on_delete: :cascade
    end
  end
end
