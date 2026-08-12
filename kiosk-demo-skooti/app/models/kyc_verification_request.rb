# frozen_string_literal: true

# A pending KYC verification skooti started at the KYC broker (design §5).
# request_kyc calls the broker's intake and stores the BROKER's request_id here
# as `request_token`, plus the broker's per-request `broker_nonce`. The agent
# relays the broker's verification_url to a human; on approve the broker POSTs
# its signed anonymized {age_over_18, licence_a} claim to POST /kyc/callback,
# which verifies it (trusted ProveKey + nonce + operator + sub) and parks the
# jws in `kyc_jws`. The agent polls `kyc_status` and submits the jws to POST
# /kiosk/agents/kyc (agent contract unchanged).
#
#   request_token — the BROKER's request_id (PK); the request_id kyc_status
#                   polls and the callback correlates on.
#   user_id       — the authenticated agent's user_id the request is bound to;
#                   the broker signs the claim's `sub` to this so KycVerifier
#                   binds it to the SAME identity (cross-subject theft defense).
#   broker_nonce  — the callback anti-replay nonce the broker returned at intake;
#                   POST /kyc/callback rejects a callback whose nonce differs.
#   status        — 'pending' → 'approved' | 'declined'.
#   kyc_jws       — the broker's signed anonymized claim, NULL until the callback
#                   lands. Only booleans are ever carried — never DOB/licence.
class KycVerificationRequest < ApplicationRecord
  self.primary_key = "request_token"

  STATUSES = %w[pending approved declined].freeze
end
