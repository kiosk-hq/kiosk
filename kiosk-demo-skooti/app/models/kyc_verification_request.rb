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
  # The two `request_kyc` writes and `kyc_status` branches on. `declined` is a
  # real state the broker can reach and is listed above; it is not named here
  # because nothing in this app compares against it.
  PENDING, APPROVED = STATUSES

  # ── THE isolation predicate, the {Reservation} one on this table ───────────
  # `kyc_status` is bound to it: an agent only ever sees the status — and the
  # jws — of a request IT opened, so it cannot poll (or lift the attestation
  # from) another agent's verification. Kept SQL-side over a frozen
  # `Arel.sql` literal for the reason written out in
  # {Reservation.owned_by_current_principal}: it is the expression an RLS
  # policy is written in.
  #
  # POST /kyc/callback deliberately does NOT use it. The broker is not a
  # principal — no GUC is set on that request at all — so the callback looks
  # the row up by its unguessable `request_token` and proves its right to it
  # with the signed claim, the stored nonce, the operator binding and the `sub`
  # match instead. That is why the two surfaces share this MODEL and no
  # behaviour: they answer to different authorities.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }
end
