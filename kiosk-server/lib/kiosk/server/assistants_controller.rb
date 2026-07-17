# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::Base)` guard below means it only defines
# the controller when full ActionController (HTML rendering) is present. In
# plain Ruby the require is a no-op. The engine draws the routes when Rails
# is present.

if defined?(::ActionController::Base)
  require "kiosk/server/account_binding"
  require "kiosk/server/link_code"
  require "kiosk/server/signing_key"

  module Kiosk
    module Server
      # The «Link an assistant» engine page (ADR-0017, link flow — Kiosk
      # extension): a session-authenticated account holder lists the
      # assistant accounts bound to them, mints link codes, and unlinks.
      #
      #   GET  <mount>/auth/assistants        — the page
      #   POST <mount>/auth/assistants/link   — mint a link code (shown once)
      #   POST <mount>/auth/assistants/unlink — deactivate a binding
      #
      # HTML shim over the same services the JSON endpoints use
      # ({LinkCode.mint}, {AccountBinding.unlink!}) — batteries-included
      # like {DeviceVerifyController}; override the view by shipping
      # app/views/kiosk/server/assistants/show.html.erb in the host app.
      class AssistantsController < ::ActionController::Base
        # Host app view paths (configured by Rails on ActionController::Base)
        # come first, so a provider's own templates override these.
        append_view_path File.expand_path("../../../app/views", __dir__)
        layout false

        def show
          return unless require_account_holder!

          render_page
        end

        def link
          return unless require_account_holder!

          result = LinkCode.mint(user_id: @identity.user_id)
          @link_code  = result[:link_code]
          @expires_in = result[:expires_in]
          render_page
        end

        def unlink
          return unless require_account_holder!

          AccountBinding.unlink!(agent_id: params[:agent_id].to_s, user_id: @identity.user_id)
          @notice = "Assistant unlinked — its key no longer signs in."
          render_page
        rescue Errors::Base => e
          @error = e.message
          render_page(status: e.http_status)
        end

        private

        def render_page(status: :ok)
          @assistants = bound_assistants
          # Forms post to <page>/link and <page>/unlink; recompute the page
          # path so the view works at any mount and after POSTs.
          @page_path = request.path.sub(%r{/(link|unlink)\z}, "")
          render :show, status: status
        end

        # Same session rule as the verify page: the provider's `user_idp`
        # session, never an agent Bearer token.
        def require_account_holder!
          @identity = Kiosk.configuration.user_idp&.verify(request)
          return true if @identity

          render plain: "Sign in to your account first to manage linked assistants.",
                 status: :unauthorized
          false
        end

        # The holder's live agent rows — id, key fingerprint, created_at.
        # Read-only SELECT on kiosk.agents (Kiosk's own table; satellite
        # neutrality holds).
        def bound_assistants
          config = Kiosk.configuration
          conn   = ::ActiveRecord::Base.connection
          conn.execute(<<~SQL).map { |row| present(row) }
            SELECT id, public_key, created_at FROM #{config.schema}.agents
            WHERE user_id = #{conn.quote(@identity.user_id)} AND revoked_at IS NULL
            ORDER BY created_at
          SQL
        end

        def present(row)
          {
            agent_id:    row.fetch("id"),
            fingerprint: fingerprint(row.fetch("public_key")),
            created_at:  row.fetch("created_at"),
          }
        end

        def fingerprint(pem)
          return "(no key)" if pem.nil? || pem.empty?

          SigningKey.from_pem(pem).kid
        rescue StandardError
          "(unreadable key)"
        end
      end
    end
  end
end
