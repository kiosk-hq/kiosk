# frozen_string_literal: true

# The account-binding requests behind the claim and link ceremonies (RFC 8628
# shape). The device and user codes are stored hashed. `requested_role` is the
# role of the approving human, never one a client asks for.
class CreateKioskDeviceAuthorizations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kiosk_device_authorizations, id: :uuid do |t|
      t.text :device_code_hash, null: false, index: { unique: true }
      # Unique among pending requests only: a finished request may share a code with an old one.
      t.text :user_code_hash, null: false, index: { unique: true, where: "status = 'pending'" }
      t.text :public_key_pem
      t.text :kind, null: false, default: 'claim'
      t.text :client_id, null: false
      t.text :requested_role
      t.text :status, null: false
      t.column :user_id, :uuid
      t.timestamptz :expires_at, null: false, index: { where: "status IN ('pending', 'approved')" }
      t.timestamptz :consumed_at
      t.timestamptz :created_at, null: false, default: -> { 'now()' }
      t.check_constraint "status IN ('pending', 'approved', 'denied', 'consumed', 'expired')",
                         name: 'kiosk_device_authorizations_status'
      t.check_constraint "kind IN ('claim', 'link')", name: 'kiosk_device_authorizations_kind'
    end
  end
end
