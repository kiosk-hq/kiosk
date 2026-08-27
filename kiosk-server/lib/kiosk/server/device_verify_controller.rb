# frozen_string_literal: true

# HTML surface (ActionController::Base, not ::API — it renders views).
# The engine draws the routes.

require "action_controller"
require "kiosk/server/device_verification"
require "kiosk/server/signing_key"

module Kiosk
  module Server
    # The human half of the claim ceremony — the verify page:
    #
    #   GET  <mount>/oauth/device/verify[?user_code=…] — code entry, then
    #        the consent panel (key fingerprint + requested-at + the access
    #        the approver is about to hand over)
    #   POST <mount>/oauth/device/verify — approve / deny decision, which is
    #        where the ceremony's ROLE is captured
    #
    # Session-authenticated via the provider's `user_idp` (binding
    # approval is the session channel's job) — an
    # unauthenticated visitor gets a 401 telling them to sign in to the
    # provider first. Batteries-included: the minimal views under
    # app/views/kiosk/server/device_verify are rendered by default and a
    # host overrides them by shipping same-named templates in its own
    # app/views (host view paths take precedence).
    #
    # Phishing guards (the verify page is the ceremony's social surface):
    # the panel always shows WHAT is being linked — the key's RFC 7638
    # fingerprint, when it asked, and the access the approval hands over —
    # and code entry is attempt-capped per session on top of the codes being
    # single-use, short-TTL and stored hashed.
    #
    # THE ROLE IS CAPTURED HERE, AND DISCLOSED HERE (ADR-0011 amendment;
    # K-1109). `@identity.role` — the provider's own answer for the human
    # whose session this is — is both what the panel names and what
    # {DeviceVerification.approve} stamps onto the row, so the human reads the
    # very value the token will carry. Before K-1109 the row's role came from
    # the unauthenticated request that opened the ceremony and this page
    # mentioned no role at all: an approver could hand over `owner` while the
    # page showed a fingerprint and a timestamp. One field could have been
    # fixed without the other, and neither alone is enough — a disclosed
    # self-selected role is still an escalation, and an undisclosed correct
    # role is still an approval given blind.
    class DeviceVerifyController < ::ActionController::Base
      # Failed user_code lookups tolerated per session before a 429.
      # Generous for fat-fingering; hopeless for guessing one of the
      # 31^8 ≈ 8.5 × 10^11 codes ({DeviceAuthorization::USER_CODE_ALPHABET}).
      MAX_CODE_ATTEMPTS = 10

      # Host app view paths (configured by Rails on ActionController::Base)
      # come first, so a provider's own templates override these.
      append_view_path File.expand_path("../../../app/views", __dir__)
      layout false

      # AGENT-SIGNPOST (K-459) — same rule as {AssistantsController}, whose
      # copy carries the full explanation. Short version: an assistant that
      # POSTs JSON to this human consent page trips Rails' forgery gate, and
      # in production Rails answers with the host's generic error material —
      # a static public/422.html, a bare status echo, or (on a host with no
      # error page) a bodyless 422 — never a pointer to the wire. Answer a
      # JSON-shaped caller with the courtesy body below + a pointer to the
      # wire; re-raise for browsers so real CSRF failures still fail. NOT «the
      # Kiosk error envelope», which is what this comment used to call it: that
      # names the wire CONTRACT, and the wire's is a flat RFC 9457 problem
      # document (K-1092). {#wrong_door_envelope} below records why this page
      # deliberately does not borrow it.
      rescue_from ::ActionController::InvalidAuthenticityToken do |error|
        raise error unless json_request?

        render json: wrong_door_envelope, status: :unprocessable_entity
      end

      def show
        return unless require_account_holder!
        return if attempt_capped!

        @user_code = params[:user_code].to_s
        @authorization = DeviceVerification.find_pending(user_code: @user_code) unless @user_code.empty?
        if !@user_code.empty? && @authorization.nil?
          record_failed_attempt
          @error = "That code was not recognised — it may have expired. Ask the assistant for a fresh one."
        end
        @fingerprint = key_fingerprint(@authorization)
        @role = @identity.role
        render :show
      end

      def create
        return unless require_account_holder!
        return if attempt_capped!

        @user_code = params[:user_code].to_s
        @role      = @identity.role
        case params[:decision].to_s
        when "approve"
          # The role travels with the approval, from the approving human's own
          # identity — see the class comment. `@identity.role` is nil for a
          # role-less `user_idp`, which binds at `registration_role`/absent.
          DeviceVerification.approve(
            user_code: @user_code, user_id: @identity.user_id, role: @identity.role,
          )
          @decision = :approved
        when "deny"
          DeviceVerification.deny(user_code: @user_code)
          @decision = :denied
        else
          return render plain: "decision must be approve or deny", status: :bad_request
        end
        render :decided
      rescue DeviceVerification::CodeNotFoundError
        record_failed_attempt
        @authorization = nil
        @error = "That code was not recognised — it may have expired. Ask the assistant for a fresh one."
        render :show, status: :unprocessable_entity
      end

      private

      # The approving human authenticates through the provider's normal
      # session (`user_idp` — e.g. the Devise adapter reading the Warden
      # user). No session → 401; the provider's own login page is the
      # remedy, not anything Kiosk ships.
      def require_account_holder!
        @identity = Kiosk.configuration.user_idp&.verify(request)
        return true if @identity

        render plain: "Sign in to your account first, then re-open this page to approve the assistant link.",
               status: :unauthorized
        false
      end

      # A machine caller for signposting purposes: an explicit JSON `Accept`,
      # or a JSON request body. Deliberately narrow — anything ambiguous
      # counts as a browser and keeps today's behaviour.
      def json_request?
        return true if request.format.json?

        !!request.content_mime_type&.json?
      rescue StandardError
        false
      end

      # The signpost body. Non-wire `error.code` on purpose: this endpoint is
      # not a wire verb, so it must not borrow a code from the spec's closed
      # error table. The SHAPE is deliberately not the wire's either — the
      # wire answers RFC 9457 problem documents, and this is an HTML page for
      # a signed-in human, so a JSON body here is a courtesy to an assistant
      # that dialed the wrong door rather than a contract anything parses.
      def wrong_door_envelope
        {
          ok:    false,
          error: {
            code:    "invalid_authenticity_token",
            message: "this is the account holder's browser consent page, not the Kiosk wire — " \
                     "it needs a signed-in session and a CSRF token from its own form",
            hint:    "assistants use the wire: GET #{request.base_url}/.well-known/kiosk.json " \
                     "for the register/login endpoints, then GET <endpoint>/schema " \
                     "(public) for the verbs this origin serves",
          },
        }
      end

      def record_failed_attempt
        session[:kiosk_verify_attempts] = session[:kiosk_verify_attempts].to_i + 1
      end

      def attempt_capped!
        return false if session[:kiosk_verify_attempts].to_i < MAX_CODE_ATTEMPTS

        render plain: "Too many code attempts — sign out and back in to retry.",
               status: :too_many_requests
        true
      end

      # RFC 7638 thumbprint of the key the ceremony would bind — the same
      # identifier kiosk-pop uses as JWK `kid`, so what the human approves
      # is checkable against what the assistant printed.
      def key_fingerprint(authorization)
        return nil if authorization&.public_key_pem.nil?

        SigningKey.from_pem(authorization.public_key_pem).kid
      rescue StandardError
        "(unreadable key)"
      end
    end
  end
end
