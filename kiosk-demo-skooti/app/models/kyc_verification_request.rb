# frozen_string_literal: true

# A pending KYC verification skooti started at the KYC broker.
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
#   status        — 'pending' → 'approved'. The broker reports an approval and
#                   nothing else, so a check the human refused stays 'pending'.
#   kyc_jws       — the broker's signed anonymized claim, NULL until the callback
#                   lands. Only booleans are ever carried — never DOB/licence.
class KycVerificationRequest < ApplicationRecord
  self.primary_key = "request_token"

  # THE TWO STATES THIS COLUMN EVER HOLDS, and the second one is the only thing
  # the broker ever tells this operator. A human who REFUSES the check tells the
  # broker so and the broker reports nothing — that silence is what it promises
  # the human — so a refused verification stays `pending` here, and a third
  # state would be one no code path can write and this validation would refuse.
  STATUSES = %w[pending approved].freeze
  PENDING, APPROVED = STATUSES
  # The column is a bare varchar with no CHECK constraint (db/structure.sql), so
  # until this validation nothing enforced the set the constant names — and a
  # status outside it silently fails BOTH `kyc_status` branches, leaving a
  # request that is neither pending nor approved and never resolves (K-712g).
  validates :status, inclusion: { in: STATUSES }

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
    # Off the wire there is no principal, so this predicate would be `= NULL`
    # and answer nothing at all; refuse instead of returning a plausible zero.
    Kiosk::Server::SessionContext.require_open!
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # ── WHAT THE EVENT SURFACE READS ───────────────────────────────────────────
  # A standing subscription is re-authorised on a timer, with no request and no
  # GUC, so this takes the account as an argument rather than reading the
  # per-request principal.
  #
  # @return [Boolean]
  def self.readable_by?(request_id, user_id)
    return false if request_id.to_s.empty? || user_id.to_s.empty?

    where(id: request_id, user_id: user_id).exists?
  end

end
