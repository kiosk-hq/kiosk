# frozen_string_literal: true

require "securerandom"

# An operator opens a verification (POST /verifications, with its bearer
# secret); the human answers it on the page the request_id links to; an
# approval is signed as an anonymized claim and posted to the operator's
# callback. No CSRF token: the intake authenticates with the secret, the page
# with the unguessable request_id.
class VerificationsController < ActionController::Base
  protect_from_forgery with: :null_session

  REQUEST_TTL = 15 * 60

  def create
    operator = authenticate_operator!
    return if performed?

    body = intake_body
    requested_claims = Array(body["requested_claims"]).map(&:to_s)
    callback_url     = body["callback_url"].to_s
    subject_handle   = body["subject_handle"].to_s
    # The audience is the registered operator's, never the body's.
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
    # The broker posts only to the operator's registered host.
    unless OperatorRegistry.callback_allowed?(operator, callback_url)
      return render_json(
        { error: "callback_url host is not allow-listed for this operator" },
        :forbidden,
      )
    end
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
      audience:         (audience.empty? ? nil : audience),
      expires_at:       Time.current + REQUEST_TTL,
    )

    render_json(
      {
        request_id:       request_id,
        verification_url: verification_url_for(request_id),
        status:           "pending",
        # The callback echoes it, so the operator can tell it from a replay.
        nonce:            nonce,
        expires_at:       (Time.current + REQUEST_TTL).utc.iso8601,
      },
      :created,
    )
  end

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

  # The public key operators verify claims with.
  def public_key
    render plain: ProveKey.public_key, content_type: "application/x-pem-file"
  end

  private

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

    @decision   = :approved
    @delivered  = delivery_status.is_a?(Integer) && (200..299).cover?(delivery_status)
    @attributes = attributes
    render :decided
  end

  # Claims the row before minting: of concurrent decisions, exactly one wins.
  def claim!(prove_request, new_status)
    claimed = ProveRequest
      .pending.where(request_id: prove_request.request_id)
      .update_all(status: new_status, updated_at: Time.current) == 1
    prove_request.status = new_status if claimed
    claimed
  end

  def lost_race_response
    @request.reload
    @entries = ClaimCatalog.entries_for(@request.requested_claims)
    render(:show, status: :unprocessable_entity)
  end

  def find_request
    token = params[:request].to_s
    return nil if token.empty?

    ProveRequest.find_by(request_id: token)
  end

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

  def verification_url_for(request_id)
    base = (Rails.configuration.x.prove.public_url || request.base_url).to_s.chomp("/")
    "#{base}/verify?request=#{request_id}"
  end

  def render_json(hash, status)
    render json: hash, status: status
  end
end
