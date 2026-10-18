# frozen_string_literal: true

module Kiosk
  module Server
    # «Link an assistant» page: a signed-in account holder lists, labels,
    # links and unlinks their assistants. Host views override
    # app/views/kiosk/server/assistants/show.html.erb.
    class AssistantsController < ApplicationController
      SIGN_IN_PROMPT = 'Sign in to your account first to manage linked assistants.'
      SIGN_IN_ALERT  = 'Please sign in to manage your linked assistants.'

      WRONG_DOOR_MESSAGE = "this is the account holder's browser page, not the Kiosk wire — " \
                           'it needs a signed-in session and a CSRF token from its own form'

      layout false

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

      # Edits a bound assistant's label and/or spending cap (blank cap → unlimited).
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
        # Without a `config.spending_cap` seam the saved cap binds nothing; the page says so.
        @spending_cap_enforced = !Kiosk.configuration.spending_cap.nil?
        @page_path = request.path.sub(%r{/(link|unlink|update)\z}, '')
        render :show, status: status
      end

      # Column name → new value; nil writes NULL.
      def settings_changes
        changes = {}
        changes['human_label'] = params[:human_label].to_s if params.key?(:human_label)
        changes['spending_cap_cents'] = spending_cap_param if params.key?(:spending_cap_cents)
        changes
      end

      def spending_cap_param
        raw = params[:spending_cap_cents].to_s
        return nil if raw.strip.empty?

        Integer(raw, exception: false) || raise(Errors::BadRequest, 'spending_cap_cents must be an integer')
      end
    end
  end
end
