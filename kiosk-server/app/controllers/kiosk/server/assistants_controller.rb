# frozen_string_literal: true

module Kiosk
  module Server
    # «Link an assistant» page: a signed-in account holder lists, labels,
    # links and unlinks their assistants. Host views override
    # app/views/kiosk/server/assistants/show.html.erb.
    class AssistantsController < ApplicationController
      SIGN_IN_PROMPT = 'Sign in to your account first to manage linked assistants.'
      SIGN_IN_ALERT  = 'Please sign in to manage your linked assistants.'
      CAP_NOT_AN_AMOUNT   = 'Write the spending cap as an amount, such as 50 or 12.50.'
      CURRENCY_NOT_A_CODE = 'Write the cap currency as a three-letter currency code, such as EUR.'

      def show
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)

        render_page
      end

      # The signed-in human's role goes on the link row, as on the JSON path;
      # `bind!` validates it at redeem.
      def link
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)

        result = LinkCode.mint(user_id: @identity.user_id, requested_role: @identity.role)
        @link_code  = result[:link_code]
        @expires_in = result[:expires_in]
        render_page
      end

      def unlink
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)

        AccountBinding.unlink!(agent_id: params[:agent_id].to_s, user_id: @identity.user_id)
        @notice = 'Assistant unlinked — its key no longer signs in.'
        render_page
      rescue Errors::Base => e
        render_error(e)
      end

      # Edits a bound assistant's label and/or spending cap and its currency (blank cap → no cap).
      def update
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)

        changes = settings_changes
        LinkedAssistants.save_settings(params[:agent_id].to_s, @identity.user_id, changes) if changes.any?
        @notice = 'Assistant settings saved.'
        render_page
      rescue Errors::Base => e
        render_error(e)
      end

      private

      def render_error(error)
        @error = error.message
        render_page(status: error.http_status)
      end

      def render_page(status: :ok)
        @assistants = LinkedAssistants.list(@identity.user_id)
        # The spend shows where the origin takes payments; the cap, where a `spending_cap` reads it.
        @payments     = !Kiosk.configuration.payment_provider.nil?
        @spending_cap = !Kiosk.configuration.spending_cap.nil?
        @page_path = request.path.sub(%r{/(link|unlink|update)\z}, '')
        render :show, status: status
      end

      # Column name → new value; nil writes NULL.
      def settings_changes
        changes = {}
        changes['human_label'] = params[:human_label].to_s if params.key?(:human_label)
        changes['spending_cap_cents'], changes['spending_cap_currency'] = spending_cap_param if params.key?(:spending_cap)
        changes
      end

      # `[cents, currency]` from the amount the person typed, or `[nil, nil]` for no cap.
      def spending_cap_param
        raw = params[:spending_cap].to_s
        return [nil, nil] if raw.strip.empty?

        currency = spending_cap_currency_param
        cents = Money.parse(raw, currency) || raise(Errors::BadRequest, CAP_NOT_AN_AMOUNT)
        [cents, currency]
      end

      def spending_cap_currency_param
        code = MandateVerifier.canonical_currency(params[:spending_cap_currency])
        return code if MandateVerifier::CURRENCY_CODE.match?(code)

        raise Errors::BadRequest, CURRENCY_NOT_A_CODE
      end
    end
  end
end
