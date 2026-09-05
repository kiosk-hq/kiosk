# frozen_string_literal: true

# request_kyc — start an 18+ verification at the KYC broker that an EXTERNAL
# agent can COMPLETE without any pre-shared issuer key.
#
# getgrocery hosts no issuer of its own: it calls the shared broker's intake
# server-to-server and stores what comes back — the request_id as this row's
# request_token, plus the broker's nonce for callback anti-replay. On approve
# the BROKER signs the claim and POSTs it to POST /kyc/callback.
#
# THE CALLBACK IS NOT A SECOND CALLER OF THIS OPERATION: it approves a request,
# which no wire verb can do, and it looks the row up UNSCOPED because the caller
# is the broker and not a principal — where both `request_kyc` and `kyc_status`
# are bound to `kiosk.current_user_id()`.
class RequestKycOperation
  # The ONE fact getgrocery asks the broker to establish: an age gate on a
  # grocery basket needs a boolean and nothing else.
  REQUESTED_CLAIMS = %w[age_over_18].freeze

  # THE OUTSTANDING-INTAKE CAP. Nothing else meters this verb — the
  # reputation policy challenges `:query` only — so without it one registration
  # proof buys unlimited broker intakes: a budget hole the day a paid issuer
  # sits behind the KYC broker.
  #
  # PENDING requests only, and that IS the design: an approved or declined
  # request is a finished conversation and must never wall its principal out,
  # while a pending one is exactly the intake a paid issuer would bill for — so
  # the cap is self-clearing, with no TTL to tune and no sweeper to run. Three
  # and not one because a human who closes the broker tab leaves a pending row
  # behind, and a cap of one would wall the account out of its only remedy.
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
        message: "too many age verifications are already open for this account",
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

    # `insert!`: no callbacks, no timestamp magic, one write. This model
    # declares no associations and no validations, so `create!` would answer the
    # wire identically — see {CreateOrderOperation}, where it would not.
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

  # Live intakes this principal is already holding. Counted through the SAME
  # isolation predicate `kyc_status` reads with, so the cap is per principal by
  # construction rather than by a `user_id` argument a caller could forget.
  def self.outstanding_for_current_principal
    KycVerificationRequest.owned_by_current_principal
                          .where(status: KycVerificationRequest::PENDING)
                          .count
  end
  private_class_method :outstanding_for_current_principal, :broker_refusal
end
