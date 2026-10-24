# frozen_string_literal: true

# The manage-assistants page shows when each assistant was linked: a binding
# records its time on the agent.
class AddBoundAtToKioskAgents < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(ALTER TABLE "kiosk".agents ADD COLUMN bound_at timestamptz)
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN bound_at)
  end
end
