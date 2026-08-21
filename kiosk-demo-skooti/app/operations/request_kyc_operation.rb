# frozen_string_literal: true

# request_kyc — start a verification at the KYC broker that an EXTERNAL agent
# can COMPLETE without any pre-shared issuer key (K-440/K-443, design §5.1).
#
# skooti does not host its own issuer: it calls the shared broker's intake
# server-to-server with its own callback_url, the two claims it needs
# (age_over_18 + licence_category:A), and the agent's user_id as the subject the
# claim must bind to. The broker returns an unguessable verification_url (on the
# BROKER) and a request_id; skooti stores that request_id as this row's
# request_token (+ the broker's nonce for callback anti-replay) and returns the
# broker's verification_url for the agent to relay to its human. On approve, the
# BROKER signs an anonymized {age_over_18, licence_a} claim and POSTs it to
# skooti's POST /kyc/callback; the agent then polls GET <endpoint>/kyc_status and
# submits the returned jws to POST /kiosk/agents/kyc (agent contract UNCHANGED —
# only the issuer behind the link changed).
#
# THE CALLBACK IS NOT A SECOND CALLER OF THIS OPERATION, and that was checked
# rather than assumed: POST /kyc/callback approves a request, which no wire verb
# can do; it looks the row up UNSCOPED, because the caller is the broker and not
# a principal, where both `request_kyc` and `kyc_status` are bound to
# `kiosk.current_user_id()`. The two surfaces share the MODEL
# ({KycVerificationRequest}) and nothing else, so there is no behaviour for them
# to hold in common.
class RequestKycOperation
  # The two facts skooti asks the broker to establish. `licence_category:A` is
  # the broker's claim vocabulary; it comes back as the anonymized boolean
  # `licence_a`, which is what {RentMotorcycleOperation} gates on.
  REQUESTED_CLAIMS = %w[age_over_18 licence_category:A].freeze

  # THE OUTSTANDING-INTAKE CAP (K-586). Before this, one registration proof
  # bought unlimited broker intakes: nothing meters this verb — skooti
  # configures no `reputation_policy` at all, `registration_pow_count` is 1,
  # and `kyc_verification_requests` carries no per-principal bound — so one
  # agent could open verifications for as long as it cared to. Free while the
  # broker is a stub that bills nothing; a direct budget hole the day a paid
  # issuer sits behind prove.my, which is the attack the K-460 vendor research
  # prescribes attempt-caps for. A licence check is the expensive kind.
  #
  # PENDING requests only, and that IS the design. An approved or declined
  # request is a finished conversation and must never wall its principal out,
  # while a pending one is exactly the outstanding intake a paid issuer would
  # bill for. So the cap is self-clearing: the human acts, or abandons and the
  # request is replaced within the allowance — no TTL to tune, no sweeper to
  # run, and no state this operation has to maintain.
  #
  # Three, not one: a human who closes the broker tab leaves a pending row
  # behind, and a cap of one would then wall the account out of the only
  # remedy it has. Three leaves room for two abandoned attempts while an
  # automated loop still hits the wall on its fourth call. It is a working
  # ceiling for a demo, not a calibrated number.
  MAX_OUTSTANDING_REQUESTS = 3

  # @param principal_id [String] the account the wire resolved — the subject the
  #   broker binds its signed claim's `sub` to, and the owner this row is stored
  #   under so `kyc_status` can only ever return it to the agent that opened it.
  def self.call(principal_id:)
    # Checked BEFORE the broker call, which is the whole point of a cap: a
    # refusal that has already cost an intake is an apology, not a limit.
    if outstanding_for_current_principal >= MAX_OUTSTANDING_REQUESTS
      return OperationResult.refused(
        code:    "quota_exceeded",
        message: "too many verifications are already open for this account",
        hint:    "at most #{MAX_OUTSTANDING_REQUESTS} may be pending at once. Have your human " \
                 "finish or abandon one of the broker pages you were already given, then poll " \
                 "`kyc_status` — a request that is approved or declined stops counting.",
      )
    end

    callback_base = Kiosk.configuration.issuer.to_s.chomp("/")
    broker = ProveBrokerClient.start_verification(
      callback_url:     "#{callback_base}/kyc/callback",
      requested_claims: REQUESTED_CLAIMS,
      subject_handle:   principal_id.to_s,
    )

    request_id       = broker.fetch("request_id")
    verification_url = broker.fetch("verification_url")
    nonce            = broker["nonce"].to_s

    # `insert!`, matching the raw INSERT statement for statement: no callbacks,
    # no timestamp magic, one write. Here it is not the load-bearing choice it
    # is in {ReserveOperation} — this model declares no associations and no
    # validations, so `create!` was measured to raise the same
    # `ActiveRecord::RecordNotUnique` on a duplicate request_token (the primary
    # key) and would answer the wire identically. `insert!` is kept for the same
    # reason the sibling write uses it: the Operation says exactly what it does.
    now = Time.current
    KycVerificationRequest.insert!(
      { request_token: request_id,
        user_id:       principal_id,
        broker_nonce:  nonce,
        status:        KycVerificationRequest::PENDING,
        created_at:    now,
        updated_at:    now },
    )

    OperationResult.ok({
      request_id:       request_id,
      verification_url: verification_url,
      status:           KycVerificationRequest::PENDING,
    })
  end

  # Live intakes this principal is already holding. Counted through the SAME
  # isolation predicate `kyc_status` reads with, so the cap is per principal by
  # construction rather than by a `user_id` argument a caller could forget to
  # pass — and an RLS-enforced session counts the identical rows.
  def self.outstanding_for_current_principal
    KycVerificationRequest.owned_by_current_principal
                          .where(status: KycVerificationRequest::PENDING)
                          .count
  end
  private_class_method :outstanding_for_current_principal
end
