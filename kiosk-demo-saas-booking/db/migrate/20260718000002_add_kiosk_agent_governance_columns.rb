# frozen_string_literal: true

# Adds the per-assistant governance columns (spending_cap_cents + human_label)
# to kiosk.agents (ADR-0019). Thin wrapper over
# Kiosk::Server::SchemaDefinitions.agent_governance_columns_sql — read/written
# by the manage-assistants page and enforced in the pay path via the
# config.spending_cap seam (Kiosk::Server::ColumnSpendingCap).
class AddKioskAgentGovernanceColumns < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.agent_governance_columns_sql(schema: "kiosk")
  end

  def down
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS spending_cap_cents)
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS human_label)
  end
end
