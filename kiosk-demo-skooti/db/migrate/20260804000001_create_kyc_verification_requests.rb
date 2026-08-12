# frozen_string_literal: true

# A pending age+licence verification skooti started at the KYC broker (design
# §5). `request_kyc` calls the broker's intake for the claims the motorcycle
# gate needs — `age_over_18` + `licence_a` (contrast getgrocery's single
# age_over_18 for the alcohol gate) — and stores the BROKER's request_id here
# as `request_token`. The agent relays the broker's verification_url to a
# human; on approve the broker POSTs its signed anonymized {age_over_18,
# licence_a} claim to POST /kyc/callback, which verifies it (trusted ProveKey
# + nonce + operator + sub) and parks the jws in `kyc_jws`. The agent polls
# `kyc_status` and submits the jws to POST /kiosk/agents/kyc (agent contract
# unchanged), then retries rent_motorcycle. (The table predates the broker
# rewire — it was the retired K-440/K-443 stub-issuer state; routes.rb: the
# broker now owns issuance. The callback anti-replay `broker_nonce` column
# arrives in the follow-up 20260804000002 migration.)
#
#   request_token — the BROKER's request_id (PK); the request_id kyc_status
#                   polls and the callback correlates on.
#   user_id       — the authenticated agent's user_id the request is bound to;
#                   the broker signs the claim's `sub` to this so KycVerifier
#                   binds it to the SAME identity (cross-subject theft defense).
#   status        — 'pending' → 'approved' | 'declined'.
#   kyc_jws       — the broker's signed anonymized claim, NULL until the
#                   callback lands. Only booleans are ever carried — never
#                   DOB/licence number.
class CreateKycVerificationRequests < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :kyc_verification_requests, id: false do |t|
      t.string     :request_token, null: false, primary_key: true
      t.uuid       :user_id,       null: false
      t.string     :status,        null: false, default: "pending"
      t.text       :kyc_jws
      t.timestamps
    end
  end
end
