# frozen_string_literal: true

# Migration 004 — kiosk.device_authorizations: the account-binding state
# machine behind the RFC 8628-shaped claim and link ceremonies, in the shape
# DeviceAuthorizationStores::ActiveRecord reads and writes (hashed device and
# user codes, the bound public key, claim vs link).
class CreateKioskDeviceAuthorizations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.device_authorizations_sql(
      schema:       "kiosk",
      user_id_type: :uuid,
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".device_authorizations)
  end
end
