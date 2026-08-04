# frozen_string_literal: true

# A pending stub-KYC verification (K-440/K-443). Bound to the agent's user_id
# by `request_kyc`; the human approves it on the stub-issuer page, which signs
# an anonymized {age_over_18, licence_a} attestation into `kyc_jws`. The agent
# polls `kyc_status` and submits the jws to POST /kiosk/agents/kyc.
#
# `request_token` is the ONLY credential the verification_url carries — it is an
# unguessable secret, so no account/sign-in is needed to reach the approve page.
class KycVerificationRequest < ApplicationRecord
  self.primary_key = "request_token"

  STATUSES = %w[pending approved declined].freeze
end
