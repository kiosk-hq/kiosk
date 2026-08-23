# frozen_string_literal: true

# The demos' live-activity store: one append-only row per wire action, read back
# as counts by GET /demo/activity.json and by the kiosk.tech landing tile.
#
# Local and CI keep it in the demo's own database, which is what this migration
# provisions. The hosted deploy points every demo at ONE shared telemetry
# database instead (KIOSK_TELEMETRY_DB_URL) that no app migration can reach;
# deploy/telemetry-init.sql provisions that one, to the same shape.
#
# `text` and `timestamptz` are spelled out rather than left to `t.string` /
# `t.datetime` so the two provisioners agree column for column.
class CreateDemoTelemetryEvents < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :demo_telemetry_events do |t|
      t.text   :app,         null: false
      t.text   :action_kind, null: false
      t.text   :agent_hash,  null: false
      t.column :at, :timestamptz, null: false, default: -> { "now()" }
    end

    add_index :demo_telemetry_events, :at, name: "idx_demo_telemetry_events_at"
    add_index :demo_telemetry_events, %i[app at], name: "idx_demo_telemetry_events_app_at"
  end
end
