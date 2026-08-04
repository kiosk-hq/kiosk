# frozen_string_literal: true

# Rewire to the prove.my broker (design §5): skooti no longer hosts its own KYC
# issuer. request_kyc now calls the broker's intake, stores the BROKER's
# request_id as this row's request_token, and stores the broker's per-request
# nonce so the async POST /kyc/callback can check the callback echoes it
# (anti-replay, design §4.8). The kyc_jws is now filled by the callback (the
# broker signs it), not by a local stub-issuer approve page.
class AddBrokerNonceToKycVerificationRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :kyc_verification_requests, :broker_nonce, :string
  end
end
