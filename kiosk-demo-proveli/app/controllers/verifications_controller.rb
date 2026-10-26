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
    render plain: ProveliKey.public_key, content_type: 'application/x-pem-file'
  end

  private

  def open_request!(operator)
    request_id = SecureRandom.urlsafe_base64(32) # 256 bits
    nonce      = SecureRandom.urlsafe_base64(32)

    proveli_request = ProveliRequest.create!(
      request_id: request_id, operator_id: operator_id_param, callback_url: callback_url,
      requested_claims: requested_claims, subject_handle: subject_handle, nonce: nonce,
      audience: audience_for(operator), expires_at: Time.current + REQUEST_TTL
    )
    render_intake_answer(proveli_request)
  end

  def render_intake_answer(proveli_request)
    render_json(
      {
        request_id: proveli_request.request_id,
        verification_url: verification_url_for(proveli_request.request_id),
        status: 'pending',
        # The callback echoes it, so the operator can tell it from a replay.
        nonce: proveli_request.nonce,
        expires_at: proveli_request.expires_at.utc.iso8601
      },
      :created
    )
  end

  def audience_for(operator)
    # The audience is the registered operator's, never the body's.
    audience = operator[:audience].to_s
    audience.empty? ? operator_id_param : audience
  end

  def approve_answered!(proveli_request)
    return render_licence_unanswered unless licence_answered?(proveli_request)

    claim!(proveli_request, :confirmed) ? approve!(proveli_request) : render_unconfirmable
  end

  def licence_answered?(proveli_request)
    !ClaimCatalog.asks_licence?(proveli_request.requested_claims) ||
      ClaimCatalog::LICENCE_CATEGORIES.key?(params[:licence_category].to_s)
  end

  def approve!(proveli_request)
    attributes = ClaimCatalog.attributes_for(proveli_request.requested_claims, params[:licence_category])
    @decision   = :approved
    @delivered  = claim_delivered?(proveli_request, ProveliKey.mint(proveli_request, attributes))
    @attributes = attributes
    render :decided
  end

  # The first attempt runs in this request and answers the callback's status.
  # When the callback refuses it, `retry_on` queues the next attempt and
  # `perform_now` answers that job instead.
  def claim_delivered?(proveli_request, kyc_jws)
    answer = CallbackDeliveryJob.perform_now(callback_url: proveli_request.callback_url,
                                             request_id: proveli_request.request_id,
                                             kyc_jws: kyc_jws, nonce: proveli_request.nonce)
    (200..299).cover?(answer)
  end

  def decline!
    @decision = :declined
    render :decided
  end

  # Claims the row before minting. The row lock makes concurrent decisions take
  # turns: the first moves it out of `pending`, and the others find it decided.
  def claim!(proveli_request, decision)
    proveli_request.with_lock { proveli_request.pending? && proveli_request.update!(status: decision) }
  end

  def render_unconfirmable = render(:show, status: :unprocessable_content)

  def render_licence_unanswered
    @licence_unanswered = true
    render_unconfirmable
  end

  def find_request
    token = params[:request].to_s
    return nil if token.empty?

    ProveliRequest.find_by(request_id: token)
  end

  def verification_url_for(request_id)
    base = (Rails.configuration.x.proveli.public_url || request.base_url).to_s.chomp('/')
    "#{base}/verify?request=#{request_id}"
  end

  def render_json(hash, status)
    render json: hash, status: status
  end
end
