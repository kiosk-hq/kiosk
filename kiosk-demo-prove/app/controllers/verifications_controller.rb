# frozen_string_literal: true

require 'securerandom'

# An operator opens a verification (POST /verifications, with its bearer
# secret); the human answers it on the page the request_id links to; an
# approval is signed as an anonymized claim and posted to the operator's
# callback. No CSRF token: the intake authenticates with the secret, the page
# with the unguessable request_id.
class VerificationsController < ApplicationController
  include OperatorIntake

  protect_from_forgery with: :null_session

  REQUEST_TTL = 15 * 60

  def create
    operator = authenticate_operator!
    return if performed?

    error, status = intake_refusal(operator)
    return render_json({ error: error }, status) if error

    open_request!(operator)
  end

  def show
    @request = find_request
    @entries = request_entries
    render :show
  end

  def decide
    @request = find_request
    return render_unconfirmable unless @request&.confirmable?

    case params[:decision].to_s
    when 'approve' then claim!(@request, 'confirmed') ? approve!(@request) : lost_race_response
    when 'decline' then claim!(@request, 'declined') ? decline! : lost_race_response
    else render plain: 'decision must be approve or decline', status: :bad_request
    end
  end

  # The public key operators verify claims with.
  def public_key
    render plain: ProveKey.public_key, content_type: 'application/x-pem-file'
  end

  private

  def open_request!(operator)
    request_id = SecureRandom.urlsafe_base64(32) # 256 bits
    nonce      = SecureRandom.urlsafe_base64(32)

    ProveRequest.create!(
      request_id: request_id, operator_id: operator_id_param, callback_url: callback_url,
      requested_claims: requested_claims, subject_handle: subject_handle, nonce: nonce,
      audience: audience_for(operator).presence, expires_at: Time.current + REQUEST_TTL
    )
    render_intake_answer(request_id, nonce)
  end

  def render_intake_answer(request_id, nonce)
    render_json(
      {
        request_id: request_id,
        verification_url: verification_url_for(request_id),
        status: 'pending',
        # The callback echoes it, so the operator can tell it from a replay.
        nonce: nonce,
        expires_at: (Time.current + REQUEST_TTL).utc.iso8601
      },
      :created
    )
  end

  def audience_for(operator)
    # The audience is the registered operator's, never the body's.
    audience = operator[:audience].to_s
    audience.empty? ? operator_id_param : audience
  end

  def approve!(prove_request)
    attributes = ClaimCatalog.attributes_for(prove_request.requested_claims)
    delivery_status = deliver_claim(prove_request, ProveKey.mint(prove_request, attributes))

    @decision   = :approved
    @delivered  = delivery_status.is_a?(Integer) && (200..299).cover?(delivery_status)
    @attributes = attributes
    render :decided
  end

  def deliver_claim(prove_request, kyc_jws)
    CallbackPoster.deliver(callback_url: prove_request.callback_url, request_id: prove_request.request_id,
                           kyc_jws: kyc_jws, nonce: prove_request.nonce)
  end

  def decline!
    @decision = :declined
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
    render_unconfirmable
  end

  def render_unconfirmable
    @entries = request_entries
    render(:show, status: :unprocessable_entity)
  end

  def request_entries = @request ? ClaimCatalog.entries_for(@request.requested_claims) : []

  def find_request
    token = params[:request].to_s
    return nil if token.empty?

    ProveRequest.find_by(request_id: token)
  end

  def verification_url_for(request_id)
    base = (Rails.configuration.x.prove.public_url || request.base_url).to_s.chomp('/')
    "#{base}/verify?request=#{request_id}"
  end

  def render_json(hash, status)
    render json: hash, status: status
  end
end
