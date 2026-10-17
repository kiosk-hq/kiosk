# frozen_string_literal: true

# Migration 004 — kiosk.device_authorizations: the account-binding state
# machine behind the RFC 8628-shaped claim and link ceremonies, in the shape
# DeviceAuthorizationStores::ActiveRecord reads and writes (hashed device and
# user codes, the bound public key, claim vs link).
class CreateKioskDeviceAuthorizations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".device_authorizations (
        id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        device_code_hash text NOT NULL,
        user_code_hash   text NOT NULL,
        public_key_pem   text,
        kind             text NOT NULL DEFAULT 'claim',
        client_id        text NOT NULL,
        requested_role   text,
        status           text NOT NULL,
        user_id          uuid,
        expires_at       timestamptz NOT NULL,
        consumed_at      timestamptz,
        created_at       timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT device_authorizations_status_check
          CHECK (status IN ('pending', 'approved', 'denied', 'consumed', 'expired')),
        CONSTRAINT device_authorizations_kind_check
          CHECK (kind IN ('claim', 'link'))
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_device_authorizations_code_hash
        ON "kiosk".device_authorizations (device_code_hash);
      -- Only `pending` rows need a unique user_code; approved/consumed
      -- rows may share codes from past flows without collision.
      CREATE UNIQUE INDEX IF NOT EXISTS idx_device_authorizations_user_code_pending
        ON "kiosk".device_authorizations (user_code_hash)
        WHERE status = 'pending';
      CREATE INDEX IF NOT EXISTS idx_device_authorizations_expiry
        ON "kiosk".device_authorizations (expires_at)
        WHERE status IN ('pending', 'approved');
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".device_authorizations)
  end
end
