# frozen_string_literal: true

# request_kyc — start an 18+ verification at the KYC broker that an EXTERNAL
# agent can COMPLETE without any pre-shared issuer key (design §5.1).
#
# getgrocery does not host its own issuer: it calls the shared broker's intake
# server-to-server with its own callback_url, the SINGLE claim it needs
# (age_over_18 — NOT a driving licence), and the agent's user_id as the subject
# the claim must bind to. The broker returns an unguessable verification_url (on
# the BROKER) and a request_id; getgrocery stores that request_id as this row's
# request_token (+ the broker's nonce for callback anti-replay) and returns the
# broker's verification_url for the agent to relay to its human. On approve, the
# BROKER signs an anonymized {age_over_18} claim and POSTs it to getgrocery's
# POST /kyc/callback; the agent then polls `query kyc_status` and submits the
# returned jws to POST /kiosk/agents/kyc, then retries create_order for the
# alcohol cart.
#
# THE CALLBACK IS NOT A SECOND CALLER OF THIS OPERATION, and that was checked
# rather than assumed: POST /kyc/callback approves a request, which no wire verb
# can do; it looks the row up UNSCOPED, because the caller is the broker and not
# a principal, where both `request_kyc` and `kyc_status` are bound to
# `kiosk.current_user_id()`. The two surfaces share the MODEL
# ({KycVerificationRequest}) and nothing else, so there is no behaviour for them
# to hold in common — unlike the paid-state read, which IS shared with the
# operator's back office (see {Order.settling}).
class RequestKycOperation
  # The ONE fact getgrocery asks the broker to establish. An age gate on a
  # grocery basket needs a boolean and nothing else; asking for more would be
  # collecting what the demo exists to argue against collecting.
  REQUESTED_CLAIMS = %w[age_over_18].freeze

  # @param principal_id [String] the account the wire resolved — the subject the
  #   broker binds its signed claim's `sub` to, and the owner this row is stored
  #   under so `kyc_status` can only ever return it to the agent that opened it.
  def self.call(principal_id:)
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
    # no timestamp magic, one write. This model declares no associations and no
    # validations, so `create!` was measured to raise the same
    # `ActiveRecord::RecordNotUnique` on a duplicate request_token (the primary
    # key) and would answer the wire identically; `insert!` is kept for the same
    # reason the sibling write uses it — the Operation says exactly what it does.
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
end
