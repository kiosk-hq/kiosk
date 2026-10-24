# frozen_string_literal: true

require 'securerandom'

# An operator opens a verification (POST /verifications, with its bearer
# secret); the human answers it on the page the request_id links to, and
# chooses a licence category when the operator asks about a licence; an
# approval is signed as an anonymized claim and posted to the operator's
# callback, again from a job while the callback refuses it. No CSRF token: the
# intake authenticates with the secret, the page with the unguessable request_id.
class VerificationsController < ApplicationController
  include OperatorIntake

  protect_from_forgery with: :null_session
  rescue_from(ActionDispatch::Http::Parameters::ParseError) { render_json({ error: 'the body is not JSON' }, :bad_request) }

  REQUEST_TTL = 15 * 60

  def show
    @request = find_request
    render :show
  end

  def create
    operator = authenticate_operator!
    return if performed?

    error, status = intake_refusal(operator)
    return render_json({ error: error }, status) if error

    open_request!(operator)
  end

  def decide
    @request = find_request
    return render_unconfirmable unless @request&.confirmable?

    case params[:decision].to_s
    when 'approve' then approve_answered!(@request)
    when 'decline' then claim!(@request, :declined) ? decline! : render_unconfirmable
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

    prove_request = ProveRequest.create!(
      request_id: request_id, operator_id: operator_id_param, callback_url: callback_url,
      requested_claims: requested_claims, subject_handle: subject_handle, nonce: nonce,
      audience: audience_for(operator), expires_at: Time.current + REQUEST_TTL
    )
    render_intake_answer(prove_request)
  end

  def render_intake_answer(prove_request)
    render_json(
      {
        request_id: prove_request.request_id,
        verification_url: verification_url_for(prove_request.request_id),
        status: 'pending',
        # The callback echoes it, so the operator can tell it from a replay.
        nonce: prove_request.nonce,
        expires_at: prove_request.expires_at.utc.iso8601
      },
      :created
    )
  end

  def audience_for(operator)
    # The audience is the registered operator's, never the body's.
    audience = operator[:audience].to_s
    audience.empty? ? operator_id_param : audience
  end

  def approve_answered!(prove_request)
    return render_licence_unanswered unless licence_answered?(prove_request)

    claim!(prove_request, :confirmed) ? approve!(prove_request) : render_unconfirmable
  end

  def licence_answered?(prove_request)
    !ClaimCatalog.asks_licence?(prove_request.requested_claims) ||
      ClaimCatalog::LICENCE_CATEGORIES.key?(params[:licence_category].to_s)
  end

  def approve!(prove_request)
    attributes = ClaimCatalog.attributes_for(prove_request.requested_claims, params[:licence_category])
    @decision   = :approved
    @delivered  = claim_delivered?(prove_request, ProveKey.mint(prove_request, attributes))
    @attributes = attributes
    render :decided
  end

  # The first attempt runs in this request and answers the callback's status.
  # When the callback refuses it, `retry_on` queues the next attempt and
  # `perform_now` answers that job instead.
  def claim_delivered?(prove_request, kyc_jws)
    answer = CallbackDeliveryJob.perform_now(callback_url: prove_request.callback_url,
                                             request_id: prove_request.request_id,
                                             kyc_jws: kyc_jws, nonce: prove_request.nonce)
    (200..299).cover?(answer)
  end

  def decline!
    @decision = :declined
    render :decided
  end

  # Claims the row before minting. The row lock makes concurrent decisions take
  # turns: the first moves it out of `pending`, and the others find it decided.
  def claim!(prove_request, decision)
    prove_request.with_lock { prove_request.pending? && prove_request.update!(status: decision) }
  end

  def render_unconfirmable = render(:show, status: :unprocessable_content)

  def render_licence_unanswered
    @licence_unanswered = true
    render_unconfirmable
  end

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
