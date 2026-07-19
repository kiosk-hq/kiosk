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
      # The «Link an assistant» engine page (link flow — Kiosk
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

        # Edit a bound assistant's human label and/or spending cap.
        # Ownership-scoped: the UPDATE's WHERE pins both the agent id AND the
        # session holder's user_id, so a holder may only touch their own live
        # rows. Empty spending_cap_cents → NULL (unlimited); a non-integer
        # value is rejected as a bad request.
        def update
          return unless require_account_holder!

          conn = ::ActiveRecord::Base.connection
          assignments = []

          if params.key?(:human_label)
            assignments << "human_label = #{conn.quote(params[:human_label].to_s)}"
          end

          if params.key?(:spending_cap_cents)
            raw = params[:spending_cap_cents].to_s
            if raw.strip.empty?
              assignments << "spending_cap_cents = NULL"
            else
              cents = Integer(raw, exception: false)
              raise Errors::BadRequest, "spending_cap_cents must be an integer" if cents.nil?

              assignments << "spending_cap_cents = #{cents}"
            end
          end

          if assignments.any?
            conn.execute(<<~SQL)
              UPDATE #{Kiosk.configuration.schema}.agents
              SET #{assignments.join(", ")}
              WHERE id = #{conn.quote(params[:agent_id].to_s)}
                AND user_id = #{conn.quote(@identity.user_id)}
                AND revoked_at IS NULL
            SQL
          end

          @notice = "Assistant settings saved."
          render_page
        rescue Errors::Base => e
          @error = e.message
          render_page(status: e.http_status)
        end

        private

        def render_page(status: :ok)
          @assistants = bound_assistants
          # Forms post to <page>/link, <page>/unlink and <page>/update;
          # recompute the page path so the view works at any mount and after POSTs.
          @page_path = request.path.sub(%r{/(link|unlink|update)\z}, "")
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

        # The holder's live agent rows — id, key fingerprint, created_at,
        # human_label, spending_cap_cents, and settled_cents (this assistant's
        # settled spend, summed from the settlements receipt table via a
        # correlated subquery, respecting the optional rolling window).
        # Read-only SELECT on kiosk.agents (Kiosk's own table; satellite
        # neutrality holds).
        #
        # Providers with no payment surface never migrate a settlements table
        # (e.g. stylish): when the correlated subquery hits a missing
        # table, fall back to a spend-free listing (settled 0) so the
        # governance page still works.
        def bound_assistants
          config = Kiosk.configuration
          conn   = ::ActiveRecord::Base.connection
          rows =
            begin
              conn.execute(bound_assistants_sql(config, conn, settled_spend: true))
            rescue ::ActiveRecord::StatementInvalid
              conn.execute(bound_assistants_sql(config, conn, settled_spend: false))
            end
          rows.map { |row| present(row) }
        end

        # `settled_spend:` toggles the correlated settlements subquery. false
        # (or a schema with no settlements table) yields a constant 0.
        def bound_assistants_sql(config, conn, settled_spend:)
          <<~SQL
            SELECT id, public_key, created_at, human_label, spending_cap_cents,
                   #{settled_cents_expr(config, settled_spend: settled_spend)} AS settled_cents
            FROM #{config.schema}.agents
            WHERE user_id = #{conn.quote(@identity.user_id)} AND revoked_at IS NULL
            ORDER BY created_at
          SQL
        end

        # Correlated subquery summing this agent's settled spend from the
        # settlements table (COALESCE → 0 when it has settled nothing, or the
        # table has no rows), honouring spending_cap_window_days when set.
        def settled_cents_expr(config, settled_spend:)
          return "0" unless settled_spend

          window_days = config.spending_cap_window_days
          window = window_days ? "AND settled_at >= now() - #{window_days.to_i} * INTERVAL '1 day'" : ""
          <<~SQL.strip
            (SELECT COALESCE(SUM(settled_amount_cents), 0)
             FROM #{config.schema}.settlements
             WHERE agent_id = agents.id #{window})
          SQL
        end

        def present(row)
          cap = row.fetch("spending_cap_cents", nil)
          {
            agent_id:           row.fetch("id"),
            fingerprint:        fingerprint(row.fetch("public_key")),
            created_at:         row.fetch("created_at"),
            human_label:        row.fetch("human_label", nil),
            spending_cap_cents: cap.nil? ? nil : cap.to_i,
            settled_cents:      row.fetch("settled_cents", 0).to_i,
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
