# frozen_string_literal: true

# Migration 002 — Kiosk identity tables: agents, agent_tokens, agent_mappings.
class CreateKioskIdentityTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".agents (
        id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id             uuid NOT NULL REFERENCES "users"(id) ON DELETE CASCADE,
        allowed_roles       text[] NOT NULL DEFAULT '{}'::text[],
        public_key          text,
        human_label         text,
        spending_cap_cents  bigint,
        created_at          timestamptz NOT NULL DEFAULT now(),
        revoked_at          timestamptz,
        issuer              text NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_agents_user_id ON "kiosk".agents (user_id) WHERE revoked_at IS NULL;
      -- Dedupe at the DB, not via SELECT-then-INSERT (TOCTOU): two LIVE
      -- rows for one public key on one origin cannot coexist. Partial
      -- (WHERE revoked_at IS NULL) so a revoked key can re-register.
      CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_issuer_public_key_live
        ON "kiosk".agents (issuer, public_key) WHERE revoked_at IS NULL;

      CREATE TABLE IF NOT EXISTS "kiosk".agent_tokens (
        id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        agent_id    uuid NOT NULL REFERENCES "kiosk".agents(id) ON DELETE CASCADE,
        token_hash  text NOT NULL,
        issued_at   timestamptz NOT NULL DEFAULT now(),
        expires_at  timestamptz NOT NULL,
        revoked_at  timestamptz
      );
      CREATE INDEX IF NOT EXISTS idx_agent_tokens_agent_id ON "kiosk".agent_tokens (agent_id);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_tokens_hash ON "kiosk".agent_tokens (token_hash);

      CREATE TABLE IF NOT EXISTS "kiosk".agent_mappings (
        provider     text NOT NULL,
        external_id  text NOT NULL,
        agent_id     uuid NOT NULL REFERENCES "kiosk".agents(id) ON DELETE CASCADE,
        PRIMARY KEY (provider, external_id)
      );
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".agent_mappings)
    execute %(DROP TABLE IF EXISTS "kiosk".agent_tokens)
    execute %(DROP TABLE IF EXISTS "kiosk".agents)
  end
end
