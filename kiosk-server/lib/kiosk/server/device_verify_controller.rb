# frozen_string_literal: true

require "action_controller"
require "kiosk/server/device_verification"
require "kiosk/server/signing_key"

module Kiosk
  module Server
    # The verify page where a signed-in human approves or denies an assistant
    # link. The role the panel shows is the role the approval stamps: the
    # human's own, never one the assistant asked for.
    class DeviceVerifyController < ::ActionController::Base
      include AccountHolderGate
      include BindingModuleGate
      prepend_before_action :refuse_unserved_binding

      SIGN_IN_PROMPT = "Sign in to your account first, then re-open this page to approve the assistant link."
      SIGN_IN_ALERT  = "Please sign in to approve the assistant link."

      # Failed code lookups per session before a 429, against 31^8 possible codes.
      MAX_CODE_ATTEMPTS = 10

      # Host templates of the same name override these.
      append_view_path File.expand_path("../../../app/views", __dir__)
      layout false

      # An assistant POSTing JSON here is pointed at the wire; browsers still fail CSRF.
      rescue_from ::ActionController::InvalidAuthenticityToken do |error|
        raise error unless json_request?

        render json: wrong_door_envelope, status: :unprocessable_entity
      end

      def show
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)
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
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)
        return if attempt_capped!

        @user_code = params[:user_code].to_s
        @role      = @identity.role
        case params[:decision].to_s
        when "approve"
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

      def json_request?
        return true if request.format.json?

        !!request.content_mime_type&.json?
      rescue StandardError
        false
      end

      # Deliberately not a wire problem document or wire error code: this page is not the wire.
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

      # The key's RFC 7638 thumbprint, the `kid` the assistant prints.
      def key_fingerprint(authorization)
        return nil if authorization&.public_key_pem.nil?

        SigningKey.from_pem(authorization.public_key_pem).kid
      rescue StandardError
        "(unreadable key)"
      end
    end
  end
end
