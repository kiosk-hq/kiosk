# frozen_string_literal: true

# Migration 001 — Kiosk schema + the four current_*() helper functions.
#
# `ActiveRecord::Migration[…]` resolves at host-app load time, so this
# file picks up whatever Rails version the host is on.
class CreateKioskSchema < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE SCHEMA IF NOT EXISTS "kiosk";

      CREATE OR REPLACE FUNCTION "kiosk".current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$
        SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid
      $$;

      CREATE OR REPLACE FUNCTION "kiosk".current_role() RETURNS text LANGUAGE sql STABLE AS $$
        SELECT NULLIF(current_setting('app.current_role', true), '')
      $$;

      CREATE OR REPLACE FUNCTION "kiosk".current_actor() RETURNS text LANGUAGE sql STABLE AS $$
        SELECT NULLIF(current_setting('app.current_actor', true), '')
      $$;

      CREATE OR REPLACE FUNCTION "kiosk".current_agent_id() RETURNS uuid LANGUAGE sql STABLE AS $$
        SELECT NULLIF(current_setting('app.current_agent_id', true), '')::uuid
      $$;
    SQL
  end

  def down
    execute %(DROP SCHEMA IF EXISTS "kiosk" CASCADE)
  end
end
