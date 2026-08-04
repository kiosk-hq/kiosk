# frozen_string_literal: true

# Demo-local stub KYC-issuer state (K-440/K-443).
#
# A pending "verify your age + category-A licence" request an EXTERNAL agent
# opens with `run request_kyc`, then relays to a human via the returned
# verification_url. The human approves on skooti's own stub-issuer page; on
# approve the stub issuer signs an anonymized attestation {age_over_18,
# licence_a} with StubKyc's key and parks the JWS here for the agent to poll.
#
#   request_token — unguessable per-request secret; the ONLY credential the
#                   verification_url carries (no account/sign-in). PK.
#   user_id       — the authenticated agent's user_id the request is bound to;
#                   the attestation's `sub` is set to this, so the KycVerifier
#                   binds the issued jws to the SAME identity that requested it
#                   (a different agent cannot submit someone else's jws).
#   status        — 'pending' → 'approved' | 'declined'.
#   kyc_jws       — the signed anonymized attestation, NULL until approved.
#                   Only booleans are ever carried — never DOB/licence number.
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
