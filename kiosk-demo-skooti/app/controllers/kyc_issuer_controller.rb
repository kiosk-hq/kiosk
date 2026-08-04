# frozen_string_literal: true

# The stub "KYC provider" — the human half of the motorcycle-KYC flow
# (K-440/K-443). Models a real KYC provider (age + driving-licence check)
# WITHOUT any specific vendor: the human lands here from the verification_url
# `request_kyc` returned, approves, and the provider returns a SIGNED,
# ANONYMIZED boolean claim {age_over_18: true, licence_a: true} — never the
# documents. The agent never sees the human's DOB or licence; the operator
# never sees them either.
#
#   GET  /kyc/verify?request=<token> — the approve/decline page. No sign-in:
#        the unguessable request token in the URL is the only credential.
#   POST /kyc/verify — decision=approve signs the attestation with StubKyc's
#        key (the key skooti already trusts via c.kyc_public_key) for the
#        request's bound user_id and parks the JWS for the agent to poll;
#        decision=decline marks it declined.
#
# api_only app, so (like HomeController) this inherits ActionController::Base to
# render HTML. CSRF is disabled: there is no account session to protect and the
# request token is itself the capability (a real provider would authenticate
# the human; this is a demo stub that models the click, not the liveness check).
class KycIssuerController < ActionController::Base
  protect_from_forgery with: :null_session

  def show
    @request = find_request
    render :show
  end

  def create
    @request = find_request

    if @request.nil? || @request.status != "pending"
      render :show, status: :unprocessable_entity
      return
    end

    case params[:decision].to_s
    when "approve"
      # The provider vouches for the two anonymized booleans and signs them for
      # the request's bound user_id. `sub` == that user_id, so the KycVerifier
      # binds the jws to the SAME identity that opened the request — a different
      # agent cannot submit this jws.
      jws = StubKyc.attest(
        user_id:    @request.user_id,
        attributes: { age_over_18: true, licence_a: true },
      )
      @request.update!(status: "approved", kyc_jws: jws)
      @decision = :approved
    when "decline"
      @request.update!(status: "declined")
      @decision = :declined
    else
      render plain: "decision must be approve or decline", status: :bad_request
      return
    end

    render :decided
  end

  private

  # Look the request up by its unguessable token. A blank/unknown token yields
  # nil and the view renders a "link not recognised" message — never a 500.
  def find_request
    token = params[:request].to_s
    return nil if token.empty?

    KycVerificationRequest.find_by(request_token: token)
  end
end
