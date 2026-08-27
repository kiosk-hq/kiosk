# frozen_string_literal: true

# audience — the OPERATOR-BINDING value the minted claim's `aud` carries.
# The operator declares its audience at intake (the value its engine
# Kiosk::Server::KycVerifier will compare the claim's `aud` against — its
# `kyc_audience`). Nullable: when an operator does not declare one, the broker
# mints `aud` = operator_id (the stable handle), so an older operator that sends
# no audience still binds to itself.
class AddAudienceToProveRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :prove_requests, :audience, :string, null: true
  end
end
