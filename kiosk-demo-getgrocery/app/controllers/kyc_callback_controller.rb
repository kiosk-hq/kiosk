# frozen_string_literal: true

require "jwt"

# POST /kyc/callback — the broker → operator leg (design §4.8 / §5.2). The broker
# POSTs the signed anonymized claim here once the human approves. getgrocery:
#
#   1. verifies the JWS against the trusted ProveKey (c.kyc_public_key) with the
#      same RS256 + iss + level + exp checks the engine KycVerifier applies;
#   2. correlates it to a PENDING request getgrocery initiated (the request_id it
#      stored at request_kyc time), and checks the nonce echoes what it stored
#      (no stale/replayed callback);
#   3. enforces the DEMO-LAYER cross-operator binding — the claim's `operator`
#      must be getgrocery (a claim minted for another operator, e.g. skooti, is
#      rejected HERE, at the operator, keeping the engine attestation/wire
#      UNCHANGED);
#   4. checks `sub` equals the user_id the request was bound to (belt-and-braces;
#      the agent's own /agents/kyc submit re-checks sub against the authenticated
#      agent — the IssuedKycJwsTheft defense — so this callback does NOT stamp
#      kyc_attributes itself; it PARKS the jws for the agent to fetch via
#      kyc_status, keeping the shipped /agents/kyc sub-binding on the hot path).
#
# On success the kyc_verification_requests row flips pending → approved with the
# broker's jws parked; the agent polls kyc_status, gets the jws, and submits it
# to the existing POST /kiosk/agents/kyc (unchanged agent contract).
#
# api_only app; this inherits ActionController::API. CSRF is moot — it is a
# server-to-server call authenticated by the signed claim + the correlated
# request_id/nonce, not a browser session.
class KycCallbackController < ActionController::API
  def create
    body       = parse_body
    request_id = body["request_id"].to_s
    kyc_jws    = body["kyc_jws"].to_s
    nonce      = body["nonce"].to_s

    if request_id.empty? || kyc_jws.empty?
      return render(json: { error: "missing request_id or kyc_jws" }, status: :bad_request)
    end

    row = KycVerificationRequest.find_by(request_token: request_id)
    # Only a request getgrocery actually initiated and that is still pending is
    # accepted — an unknown or already-resolved request_id is rejected.
    if row.nil? || row.status != "pending"
      return render(json: { error: "no pending verification for that request_id" }, status: :not_found)
    end

    # Nonce echo (anti stale/replay): the callback must carry the nonce getgrocery
    # stored for this request at intake time.
    if row.broker_nonce.to_s.empty? || !secure_equal?(row.broker_nonce.to_s, nonce)
      return render(json: { error: "nonce mismatch" }, status: :forbidden)
    end

    payload = verify_broker_claim(kyc_jws)
    return if performed? # verify_broker_claim rendered an error

    # Cross-operator binding at the DEMO LAYER (build decision): the claim must
    # be addressed to getgrocery. A claim minted for a different operator is
    # rejected here — the engine attestation/wire stays UNCHANGED.
    unless secure_equal?(payload["operator"].to_s, ProveTrust.operator_id)
      return render(json: { error: "claim addressed to a different operator" }, status: :forbidden)
    end

    # Subject binding: the claim's sub must equal the user_id getgrocery bound
    # this request to at intake. (The agent's later /agents/kyc submit re-checks
    # sub against the AUTHENTICATED agent — the primary IssuedKycJwsTheft defense.)
    unless secure_equal?(payload["sub"].to_s, row.user_id.to_s)
      return render(json: { error: "claim subject does not match the requesting agent" }, status: :forbidden)
    end

    # Park the broker's jws for the agent to fetch via kyc_status and submit to
    # the existing /agents/kyc (agent contract unchanged; sub-binding preserved).
    row.update!(status: "approved", kyc_jws: kyc_jws)

    render json: { ok: true }, status: :ok
  end

  private

  # Verify the broker's claim exactly as the engine KycVerifier would: RS256
  # against the trusted ProveKey, iss == the configured broker issuer,
  # aud == this operator's kyc_audience, level == "verified", not expired.
  # Renders a 403 and returns nil on any failure.
  def verify_broker_claim(raw_jws)
    key = OpenSSL::PKey::RSA.new(Kiosk.configuration.kyc_public_key)
    payload, = JWT.decode(
      raw_jws, key, true,
      algorithms:        ["RS256"],
      verify_expiration: true,
      required_claims:   ["exp", "iss", "aud", "sub"],
    )

    if payload["iss"] != Kiosk.configuration.kyc_issuer
      render(json: { error: "issuer mismatch" }, status: :forbidden)
      return nil
    end
    if payload["aud"].to_s != Kiosk.configuration.kyc_audience.to_s
      render(json: { error: "audience mismatch" }, status: :forbidden)
      return nil
    end
    if payload["level"] != "verified"
      render(json: { error: "level not verified" }, status: :forbidden)
      return nil
    end

    payload
  rescue JWT::ExpiredSignature
    render(json: { error: "claim expired" }, status: :forbidden)
    nil
  rescue JWT::DecodeError => e
    render(json: { error: "claim signature invalid: #{e.message}" }, status: :forbidden)
    nil
  end

  def parse_body
    raw = request.raw_post
    return {} if raw.nil? || raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Length-safe constant-time-ish string comparison.
  def secure_equal?(a, b)
    require "rack/utils"
    Rack::Utils.secure_compare(a.to_s, b.to_s)
  rescue StandardError
    a.to_s == b.to_s
  end
end
