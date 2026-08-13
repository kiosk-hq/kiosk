# frozen_string_literal: true

require "securerandom"

# The broker's three legs (design §4):
#
#   POST /verifications  — INTAKE (operator → broker, server-to-server). The
#     operator authenticates with its shared bearer secret, names the requested
#     claims, its callback_url, and the subject_handle the claim must bind to.
#     The broker mints an unguessable 256-bit request_id + nonce, stores a
#     pending prove_requests row, and returns a verification_url. A confirmer
#     CANNOT reach this — only an operator initiates (§4.1).
#
#   GET  /verify?request=<id>  — the human verification page. The request_id in
#     the URL is the ONLY credential (no sign-in — demo stub). Shows the yes/no
#     questions for the requested claims (§4.2).
#
#   POST /verify  — the human's decision. On approve, the broker mints a SIGNED,
#     ANONYMIZED claim bound to (subject + operator + request), flips the row to
#     confirmed (single-use), and POSTs it to the operator's callback (§4.3/4.8).
#
#   GET  /prove_key.pem — the ProveKey public PEM operators pin (convenience).
#
# CSRF is disabled: the intake is a server-to-server JSON call authenticated by
# the bearer secret, and the verify page's credential is the unguessable request
# token itself (a real broker would authenticate the human via a govt IdP — §7).
class VerificationsController < ActionController::Base
  protect_from_forgery with: :null_session

  # 15-minute TTL for a verification request (design §4.1).
  REQUEST_TTL = 15 * 60

  # ── INTAKE: operator → broker ────────────────────────────────────────────
  def create
    operator = authenticate_operator!
    return if performed?

    body = intake_body
    requested_claims = Array(body["requested_claims"]).map(&:to_s)
    callback_url     = body["callback_url"].to_s
    subject_handle   = body["subject_handle"].to_s
    # The operator-binding `aud` is derived from the AUTHENTICATED OPERATOR'S
    # REGISTRATION record — the audience the broker holds for this allow-listed
    # operator — NOT from the request body (K-550). An operator can therefore only
    # ever obtain an attestation bound to ITS OWN audience: operator B cannot
    # request `{audience: <operator A's audience>}` and receive an A-audience
    # ProveKey-signed claim. Defaults to the operator_id handle when the operator
    # registered no distinct audience.
    audience = operator[:audience].to_s
    audience = operator_id_param if audience.empty?

    if subject_handle.empty?
      return render_json({ error: "missing field: subject_handle" }, :bad_request)
    end
    unless ClaimCatalog.all_known?(requested_claims)
      return render_json(
        { error: "unknown or empty requested_claims; broker can answer: #{ClaimCatalog::ENTRIES.keys.inspect}" },
        :bad_request,
      )
    end
    # SSRF / open-relay guard (§4.7): the callback_url MUST target the operator's
    # pre-registered host. The broker never POSTs to a free-form URL.
    unless OperatorRegistry.callback_allowed?(operator, callback_url)
      return render_json(
        { error: "callback_url host is not allow-listed for this operator" },
        :forbidden,
      )
    end
    # BIND-AND-VERIFY the operator's own declared audience (K-550): the honest
    # operator still sends its kyc_audience in the body so its intent is explicit,
    # but the broker refuses to be told a DIFFERENT audience than the one it holds
    # for this operator. A body audience that matches the registration is accepted;
    # a mismatch is REJECTED (fail loud on a cross-operator forgery attempt or an
    # operator↔broker audience misconfiguration) rather than silently overriding
    # the registration-bound value.
    declared_audience = body["audience"].to_s
    unless declared_audience.empty? || declared_audience == audience
      return render_json(
        { error: "audience does not match this operator's registration" },
        :forbidden,
      )
    end

    request_id = SecureRandom.urlsafe_base64(32) # 256 bits
    nonce      = SecureRandom.urlsafe_base64(32)

    ProveRequest.create!(
      request_id:       request_id,
      operator_id:      operator_id_param,
      callback_url:     callback_url,
      requested_claims: requested_claims,
      subject_handle:   subject_handle,
      nonce:            nonce,
      # The registration-derived audience (never the raw request body) — this is
      # what mint() stamps as the attestation `aud` (K-550).
      audience:         (audience.empty? ? nil : audience),
      status:           "pending",
      expires_at:       Time.current + REQUEST_TTL,
    )

    render_json(
      {
        request_id:       request_id,
        verification_url: verification_url_for(request_id),
        status:           "pending",
        # The broker returns the per-request nonce to the operator at intake so
        # the operator can check the eventual callback echoes it (anti-replay,
        # design §4.8). The nonce is a callback-correlation secret shared
        # operator↔broker, NOT exposed on the human verification page.
        nonce:            nonce,
        expires_at:       (Time.current + REQUEST_TTL).utc.iso8601,
      },
      :created,
    )
  end

  # ── VERIFICATION PAGE: broker → human ────────────────────────────────────
  def show
    @request  = find_request
    @entries  = @request ? ClaimCatalog.entries_for(@request.requested_claims) : []
    render :show
  end

  def decide
    @request = find_request

    if @request.nil? || !@request.confirmable?
      @entries = @request ? ClaimCatalog.entries_for(@request.requested_claims) : []
      return render(:show, status: :unprocessable_entity)
    end

    case params[:decision].to_s
    when "approve"
      if claim!(@request, "confirmed")
        approve!(@request)
      else
        lost_race_response
      end
    when "decline"
      if claim!(@request, "declined")
        @decision = :declined
        render :decided
      else
        lost_race_response
      end
    else
      render plain: "decision must be approve or decline", status: :bad_request
    end
  end

  # ── ProveKey public PEM (operators pin this) ─────────────────────────────
  def public_key
    render plain: ProveKey.public_key, content_type: "application/x-pem-file"
  end

  private

  # Mint the signed anonymized claim bound to (subject + operator + request)
  # and POST it to the operator callback. Only ever reached AFTER {#claim!}
  # has already, atomically, flipped the row pending → confirmed (K-705) — so
  # by the time this method's expensive work runs, this request has already
  # won the single-use guard and no concurrent approve can duplicate it.
  def approve!(prove_request)
    attributes = ClaimCatalog.attributes_for(prove_request.requested_claims)

    kyc_jws = ProveKey.mint(
      subject:    prove_request.subject_handle,
      operator:   prove_request.operator_id,
      audience:   prove_request.audience,
      attributes: attributes,
      request_id: prove_request.request_id,
      nonce:      prove_request.nonce,
    )

    delivery_status = CallbackPoster.deliver(
      callback_url: prove_request.callback_url,
      request_id:   prove_request.request_id,
      kyc_jws:      kyc_jws,
      nonce:        prove_request.nonce,
    )

    # CallbackPoster.deliver returns the raw HTTP status or nil on a transport
    # error (see its own comment: "delivery is best-effort in the demo"). The
    # human-facing page must not claim delivery succeeded when it did not —
    # @delivered drives which of the two "Confirmed" messages decided.html.erb
    # renders. The row itself is already flipped to confirmed above and stays
    # that way either way (K-706 fixes the claim, not the retryability — see
    # K-705 for making an undelivered row retryable).
    @decision   = :approved
    @delivered  = delivery_status.is_a?(Integer) && (200..299).cover?(delivery_status)
    @attributes = attributes
    render :decided
  end

  # ── K-705: the burn IS the single-use guard ────────────────────────────────
  # The old code read #confirmable? in memory, THEN (after minting — an
  # expensive RSA sign + network POST) wrote the row unconditionally. Two
  # concurrent POST /verify on the same pending row both passed the read,
  # both minted, both delivered: a check-then-write TOCTOU, the same class as
  # K-542 (kiosk-server's PoW spent-store race). K-542's fix was to make a
  # single atomic claim op — succeed-or-fail — happen BEFORE the expensive
  # work, instead of a plain check followed by a later plain write. This is
  # that same shape at the SQL layer: ONE conditional UPDATE, scoped to
  # `WHERE status = "pending"`, executed BEFORE any minting. Postgres
  # serializes concurrent UPDATEs against the same row, so of N racing
  # decisions on one row, `update_all` returns 1 for exactly one caller and 0
  # for every other — that boolean IS the claim, and approve!/decline are only
  # ever reached by the winner.
  #
  # @param prove_request [ProveRequest]
  # @param new_status     ["confirmed", "declined"]
  # @return [Boolean] true iff THIS request won the race (and prove_request's
  #   in-memory #status now reflects it); false if a concurrent decision
  #   already claimed the row first.
  def claim!(prove_request, new_status)
    claimed = ProveRequest
      .where(request_id: prove_request.request_id, status: "pending")
      .update_all(status: new_status, updated_at: Time.current) == 1
    prove_request.status = new_status if claimed
    claimed
  end

  # A decision lost the claim race (or the row moved on between the initial
  # #confirmable? read and the claim attempt) — re-render exactly what the
  # pre-check at the top of {#decide} would have for an already-decided row.
  def lost_race_response
    @request.reload
    @entries = ClaimCatalog.entries_for(@request.requested_claims)
    render(:show, status: :unprocessable_entity)
  end

  # Look the request up by its unguessable token. Blank/unknown yields nil → the
  # view renders "link not recognised" (never a 500).
  def find_request
    token = params[:request].to_s
    return nil if token.empty?

    ProveRequest.find_by(request_id: token)
  end

  # ── intake auth: shared bearer secret + operator allow-list (§4.7) ────────
  def authenticate_operator!
    operator = OperatorRegistry.authenticate(operator_id: operator_id_param, secret: bearer_token)
    if operator.nil?
      render_json({ error: "unknown operator or bad credential" }, :unauthorized)
      return nil
    end
    operator
  end

  def operator_id_param
    intake_body["operator_id"].to_s
  end

  def bearer_token
    auth = request.headers["Authorization"].to_s
    auth.start_with?("Bearer ") ? auth.delete_prefix("Bearer ") : ""
  end

  def intake_body
    @intake_body ||= begin
      raw = request.raw_post
      raw.nil? || raw.empty? ? {} : (JSON.parse(raw) rescue {})
    end
    @intake_body.is_a?(Hash) ? @intake_body : {}
  end

  # The link base: PROVE_PUBLIC_URL when the deploy pins one (read in
  # config/environments/*.rb — K-672), else this intake request's own origin.
  def verification_url_for(request_id)
    base = (Rails.configuration.x.prove.public_url || request.base_url).to_s.chomp("/")
    "#{base}/verify?request=#{request_id}"
  end

  def render_json(hash, status)
    render json: hash, status: status
  end
end
