# frozen_string_literal: true

# Action Cable's pubsub queue, for the Kiosk event stream.
#
# This is `solid_cable`'s own table, taken on the PRIMARY database rather than
# the separate `cable` database Rails' install template assumes: this fleet
# provisions one database and one least-privilege role per app, and a second
# database for one table would be a second thing to provision, grant and back
# up. See config/cable.yml.
#
# It is a TRANSPORT, not a record: rows are fan-out messages that
# `message_retention` sweeps. The durable per-identity event tail an assistant
# resumes from with `since` is `kiosk.events`, which is a different table with
# a different lifetime.
class CreateSolidCableMessages < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :solid_cable_messages do |t|
      t.binary   :channel,      limit: 1024,      null: false
      t.binary   :payload,      limit: 536_870_912, null: false
      t.datetime :created_at,                     null: false
      t.integer  :channel_hash, limit: 8,         null: false

      t.index :channel
      t.index :channel_hash
      t.index :created_at
    end
  end
end
