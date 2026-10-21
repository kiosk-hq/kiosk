# frozen_string_literal: true

module Kiosk
  module Server
    # The verify page where a signed-in human approves or denies an assistant
    # link. The role the panel shows is the role the approval stamps: the
    # human's own, never one the assistant asked for.
    class DeviceVerifyController < ApplicationController
      SIGN_IN_PROMPT = 'Sign in to your account first, then re-open this page to approve the assistant link.'
      SIGN_IN_ALERT  = 'Please sign in to approve the assistant link.'

      CODE_NOT_RECOGNISED = 'That code was not recognised — it may have expired. Ask the assistant for a fresh one.'

      WRONG_DOOR_MESSAGE = "this is the account holder's browser consent page, not the Kiosk HTTP API — " \
                           'it needs a signed-in session and a CSRF token from its own form'

      # Failed code lookups per session before a 429, against 31^8 possible codes.
      MAX_CODE_ATTEMPTS = 10

      layout false

      def show
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)
        return render_attempts_capped if attempts_capped?

        @user_code = params[:user_code].to_s
        @authorization = find_authorization(@user_code)
        @fingerprint = key_fingerprint(@authorization)
        @role = @identity.role
        render :show
      end

      def create
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)
        return render_attempts_capped if attempts_capped?

        @user_code = params[:user_code].to_s
        @role      = @identity.role
        @decision  = decide(params[:decision].to_s)
        return render plain: 'decision must be approve or deny', status: :bad_request unless @decision

        render :decided
      rescue DeviceVerification::CodeNotFoundError
        render_code_not_recognised
      end

      private

      def find_authorization(user_code)
        return nil if user_code.empty?

        authorization = DeviceVerification.find_pending(user_code: user_code)
        if authorization.nil?
          record_failed_attempt
          @error = CODE_NOT_RECOGNISED
        end
        authorization
      end

      def render_code_not_recognised
        record_failed_attempt
        @authorization = nil
        @error = CODE_NOT_RECOGNISED
        render :show, status: :unprocessable_content
      end

      def decide(decision)
        case decision
        when 'approve'
          DeviceVerification.approve(user_code: @user_code, user_id: @identity.user_id, role: @identity.role)
          :approved
        when 'deny'
          DeviceVerification.deny(user_code: @user_code)
          :denied
        end
      end

      def record_failed_attempt
        session[:kiosk_verify_attempts] = session[:kiosk_verify_attempts].to_i + 1
      end

      def attempts_capped?
        session[:kiosk_verify_attempts].to_i >= MAX_CODE_ATTEMPTS
      end

      def render_attempts_capped
        render plain: 'Too many code attempts — sign out and back in to retry.',
               status: :too_many_requests
      end

      # The key's RFC 7638 thumbprint, the `kid` the assistant prints.
      def key_fingerprint(authorization)
        return nil if authorization&.public_key_pem.nil?

        SigningKey.from_pem(authorization.public_key_pem).kid
      rescue StandardError
        '(unreadable key)'
      end
    end
  end
end
