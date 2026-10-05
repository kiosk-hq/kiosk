# frozen_string_literal: true

# The broker's attestation travels to the assistant on the `kyc_verification`
# event, so the request row no longer holds it.
class RemoveKycJwsFromKycVerificationRequests < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_column :kyc_verification_requests, :kyc_jws, :text
  end
end
