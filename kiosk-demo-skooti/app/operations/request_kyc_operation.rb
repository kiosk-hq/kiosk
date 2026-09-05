# frozen_string_literal: true

# request_kyc — start a verification at the KYC broker that an EXTERNAL agent
# can COMPLETE without any pre-shared issuer key (K-440/K-443).
#
# skooti hosts no issuer: it calls the shared broker's intake server-to-server
# with its own callback_url, the claims it needs and the agent's user_id as the
# subject. The broker's request_id is stored as this row's request_token, plus
# the broker's nonce for callback anti-replay; its verification_url goes back to
# the agent to relay to its human.
#
# The broker's POST /kyc/callback is NOT a second caller of this Operation: it
# approves a request, which no wire verb can do, and it looks the row up
# UNSCOPED, where request_kyc and kyc_status are bound to the principal.
class RequestKycOperation
  # `licence_category:A` is the broker's claim vocabulary; it comes back as the
  # anonymized boolean `licence_a`, which {RentMotorcycleOperation} gates on.
  REQUESTED_CLAIMS = %w[age_over_18 licence_category:A].freeze

  # THE OUTSTANDING-INTAKE CAP. Nothing else meters this verb — skooti
  # configures no `reputation_policy` and `registration_pow_count` is 1 — so one
  # registration proof would otherwise buy unlimited broker intakes. Free while
  # the broker is a stub that bills nothing; a budget hole the day a paid issuer
  # sits behind the KYC broker, and a licence check is the expensive kind: it
  # reads a real document where an age boolean reads a date.
  #
  # PENDING only, so the cap is self-clearing: a finished (approved or declined)
  # request must never wall its principal out, and there is no TTL to tune and no
  # sweeper to run. Three rather than one because a human who closes the broker
  # tab leaves a pending row behind — three leaves room for two abandoned
  # attempts while an automated loop still hits the wall on its fourth call.
  MAX_OUTSTANDING_REQUESTS = 3

  # @param principal_id [String] the account the wire resolved — the `sub` the
  #   broker binds its signed claim to, and the owner this row is stored under so
  #   `kyc_status` can only ever return it to the agent that opened it.
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
    broker = begin
      ProveBrokerClient.start_verification(
        callback_url:     "#{callback_base}/kyc/callback",
        requested_claims: REQUESTED_CLAIMS,
        subject_handle:   principal_id.to_s,
      )
    rescue ProveBrokerClient::Unavailable => e
      return broker_refusal(e)
    end

    # Safe `fetch`es: {ProveBrokerClient} refuses an intake response missing
    # either field, so the only way to get here is with both present. The check
    # lives there because that is where the broker can be named.
    request_id       = broker.fetch("request_id")
    verification_url = broker.fetch("verification_url")
    nonce            = broker["nonce"].to_s

    # `insert!`: no callbacks, no timestamp magic, one write. Unlike
    # {ReserveOperation}'s, the choice is not load-bearing — this model declares
    # no associations and no validations, so `create!` answers identically.
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

  # THE BROKER IS A SECOND SERVICE, AND ITS ABSENCE MAY NOT REACH THE WIRE AS A
  # RUBY EXCEPTION. Three unrescued raises used to leave this verb answering
  # `500 action_failed` with a Ruby class name in `detail` — and, when the
  # broker's port was refused, with this operator's own broker host in it. That
  # is the opaque-500 shape the wire exists to replace, on a no-argument verb an
  # assistant can call before anything else.
  #
  # TWO ANSWERS, because they ask the assistant to do different things:
  #
  #   module_not_served (501) — this deployment opens no verifications at all.
  #     The same sentence and the same code the engine's KycVerifier already
  #     answers when no `kyc_public_key` is set, so the two halves of the KYC
  #     module agree; 501 is cacheable by default, which is right for a property
  #     of the origin.
  #   action_failed (500) — the broker did not complete this request. Transient,
  #     so it must not be the cacheable 501, and it says so in words rather than
  #     leaving an assistant to guess from a status.
  #
  # Neither sentence names the broker's URL, its response body or a Ruby class:
  # what the operator needs for that is written to the log instead, which is
  # where the diagnostic belonged all along.
  def self.broker_refusal(error)
    Rails.logger.warn("[request_kyc] broker intake refused: #{error.class}: #{error.message}")

    if error.is_a?(ProveBrokerClient::NotConfigured)
      OperationResult.refused(
        code:    "module_not_served",
        message: "this operator does not serve the KYC module",
        hint:    "no verification can be opened at this origin and retrying will not help — " \
                 "proceed as you would at an operator that offers none.",
      )
    else
      OperationResult.refused(
        code:    "action_failed",
        message: "the verification service this operator uses did not open a request",
        hint:    "nothing about your call is wrong and nothing here is yours to fix. Try " \
                 "`request_kyc` again shortly; until one succeeds, treat this account as " \
                 "unverified.",
      )
    end
  end

  # Live intakes this principal is already holding, counted through the SAME
  # isolation predicate `kyc_status` reads with — so the cap is per principal by
  # construction, not by a `user_id` argument a caller could forget to pass.
  def self.outstanding_for_current_principal
    KycVerificationRequest.owned_by_current_principal
                          .where(status: KycVerificationRequest::PENDING)
                          .count
  end
  private_class_method :outstanding_for_current_principal, :broker_refusal
end
