# frozen_string_literal: true

# Migration 007 — create kiosk.events.
# The per-identity EVENT TAIL an operator serving any topic needs. `id` is a
# bigserial, and that is what makes the protocol's event id a per-origin monotonic
# integer — one cursor then resumes every subscription on a socket with one
# integer comparison.
# `identity_key` is a user_id, not an agent_id: a human's second assistant must
# read the same tail, and a revoked assistant is stopped at the socket.
# Laid down unconditionally, like kiosk.kyc_attributes: the route is drawn
# whether or not this origin declares a topic, and an empty table costs nothing.
class CreateKioskEvents < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".events (
        id           bigserial   PRIMARY KEY,
        identity_key text        NOT NULL,
        topic        text        NOT NULL,
        subject      text,
        occurred_at  timestamptz NOT NULL,
        data         jsonb       NOT NULL,
        created_at   timestamptz NOT NULL DEFAULT now()
      );
      -- `since` for one subscriber: the cursor scan, in id order.
      CREATE INDEX IF NOT EXISTS idx_events_identity_key_id
        ON "kiosk".events (identity_key, id);
      -- The retention sweep only.
      CREATE INDEX IF NOT EXISTS idx_events_created_at
        ON "kiosk".events (created_at);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".events)
  end
end
