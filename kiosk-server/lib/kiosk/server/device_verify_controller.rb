# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::Base)` guard below means it only defines
# the controller when full ActionController (HTML rendering) is present. In
# plain Ruby the require is a no-op. The engine draws the routes when Rails
# is present.

if defined?(::ActionController::Base)
  require "kiosk/server/device_verification"
  require "kiosk/server/signing_key"

  module Kiosk
    module Server
      # The human half of the claim ceremony — the verify page:
      #
      #   GET  <mount>/oauth/device/verify[?user_code=…] — code entry, then
      #        the consent panel (key fingerprint + requested-at)
      #   POST <mount>/oauth/device/verify — approve / deny decision
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
      # fingerprint and when it asked — and code entry is attempt-capped
      # per session on top of the codes being single-use, short-TTL and
      # stored hashed.
      class DeviceVerifyController < ::ActionController::Base
        # Failed user_code lookups tolerated per session before a 429.
        # Generous for fat-fingering; hopeless for guessing 32^8 codes.
        MAX_CODE_ATTEMPTS = 10

        # Host app view paths (configured by Rails on ActionController::Base)
        # come first, so a provider's own templates override these.
        append_view_path File.expand_path("../../../app/views", __dir__)
        layout false

        # AGENT-SIGNPOST (K-459) — same rule as {AssistantsController}, whose
        # copy carries the full explanation. Short version: an assistant that
        # POSTs JSON to this human consent page trips Rails' forgery gate, and
        # in production that surfaces as a BODYLESS 422 (text/html,
        # Content-Length 0) with nothing for the caller to act on. Answer a
        # JSON-shaped caller with the Kiosk error envelope + a pointer to the
        # wire; re-raise for browsers so real CSRF failures still fail.
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
          render :show
        end

        def create
          return unless require_account_holder!
          return if attempt_capped!

          @user_code = params[:user_code].to_s
          case params[:decision].to_s
          when "approve"
            DeviceVerification.approve(user_code: @user_code, user_id: @identity.user_id)
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
        # not one of the four verbs, so it must not borrow a code from the
        # spec's wire error table — but the envelope SHAPE is the one every
        # Kiosk client already parses.
        def wrong_door_envelope
          {
            ok:    false,
            error: {
              code:    "invalid_authenticity_token",
              message: "this is the account holder's browser consent page, not the Kiosk wire — " \
                       "it needs a signed-in session and a CSRF token from its own form",
              hint:    "assistants use the wire: GET #{request.base_url}/.well-known/kiosk.json " \
                       "for the register/login and schema/query/run/pay endpoints",
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
end
