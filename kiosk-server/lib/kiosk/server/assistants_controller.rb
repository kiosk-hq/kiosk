# frozen_string_literal: true

# HTML surface (ActionController::Base, not ::API — it renders views).
# The engine draws the routes.

require "action_controller"
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

      # AGENT-SIGNPOST (K-459). This is a HUMAN, browser-only page that
      # happens to sit under the `/kiosk/…` prefix an assistant is told to
      # probe. An assistant POSTing JSON here carries no CSRF token, so Rails
      # raises ActionController::InvalidAuthenticityToken — and in production
      # nothing downstream names the machine surface. ShowExceptions hands off
      # to PublicExceptions, whose answer depends on the host and on what the
      # caller negotiated: the host's static public/422.html — every Kiosk
      # demo ships one since K-532 — when the request offered `*/*` or no
      # Accept at all; a generic `{"status":422,"error":"Unprocessable
      # Content"}` echo on an explicit JSON Accept; and, on a host shipping no
      # such page, PublicExceptions cascades and ShowExceptions#pass_response
      # answers a BODYLESS 422 (`text/html`, `Content-Length: 0`). A human
      # error page, a status echo, or nothing — none of the three points the
      # caller anywhere. Give a JSON-shaped caller a body that at least NAMES
      # a code and says where the wire is, and point it at the machine surface
      # it was actually looking for. Not a problem document: this is not a
      # wire endpoint and its code is not in the wire's closed vocabulary, so
      # borrowing the shape would claim a contract this page does not have. A
      # browser request is re-raised untouched: a genuine CSRF failure on a
      # genuine form must keep failing exactly as it does today.
      rescue_from ::ActionController::InvalidAuthenticityToken do |error|
        raise error unless json_request?

        render json: wrong_door_envelope, status: :unprocessable_entity
      end

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

        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`, which would turn this
        # governance page into a 500 on a host that took the new default.
        conn = ::ActiveRecord::Base.lease_connection

        # WHICH COLUMNS are assigned is a statement SHAPE — the form decides it
        # and the column names are literals in this file. WHAT they are assigned
        # is a value, and `human_label` in particular is FREE TEXT off a form,
        # so it is the most caller-reachable value in the auth plane: `$N`,
        # never text. `NULL` has no value to bind; the integer branch keeps its
        # `Integer()` guard, which is now about answering 400 rather than about
        # safety.
        assignments = []
        binds       = []

        if params.key?(:human_label)
          binds << params[:human_label].to_s
          assignments << "human_label = $#{binds.size}"
        end

        if params.key?(:spending_cap_cents)
          raw = params[:spending_cap_cents].to_s
          if raw.strip.empty?
            assignments << "spending_cap_cents = NULL"
          else
            cents = Integer(raw, exception: false)
            raise Errors::BadRequest, "spending_cap_cents must be an integer" if cents.nil?

            binds << cents
            assignments << "spending_cap_cents = $#{binds.size}"
          end
        end

        if assignments.any?
          # The ownership predicate is the security boundary of this action:
          # the caller supplies `agent_id`, the session supplies `user_id`.
          binds.concat([params[:agent_id].to_s, @identity.user_id])
          conn.exec_query(<<~SQL, "Kiosk assistant update", binds)
            UPDATE #{Kiosk.configuration.schema}.agents
            SET #{assignments.join(", ")}
            WHERE id = $#{binds.size - 1}
              AND user_id = $#{binds.size}
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
      #
      # When identity is absent: if the provider wired a neutral
      # `config.sign_in_path` AND this is a browser (HTML-preferring)
      # request, REDIRECT there with a flash alert and a stored return-to, so
      # a human who bookmarked the manage page lands on the operator's login
      # and is bounced back after signing in (MANAGE-PAGE-UNAUTH-UX). For a
      # non-HTML/API request, or when no sign_in_path is configured, keep the
      # bare 401 — this preserves the API contract (the engine stays
      # IdP-neutral).
      def require_account_holder!
        @identity = Kiosk.configuration.user_idp&.verify(request)
        return true if @identity

        sign_in_path = Kiosk.configuration.sign_in_path
        if sign_in_path && html_request?
          set_sign_in_flash
          store_return_location
          redirect_to sign_in_path
          return false
        end

        render plain: "Sign in to your account first to manage linked assistants.",
               status: :unauthorized
        false
      end

      # Browser vs API: prefer the negotiated format, but also accept a raw
      # `Accept: text/html` (a curl/bookmark hit whose format Rails could not
      # infer). API clients send JSON and get the plain 401 unchanged.
      def html_request?
        return true if request.format.html?

        request.headers["Accept"].to_s.include?("text/html")
      rescue StandardError
        false
      end

      # A machine caller for signposting purposes: an explicit JSON `Accept`,
      # or a JSON request body. Deliberately NARROW — anything ambiguous
      # (`*/*`, a form post, no headers at all) counts as a browser and keeps
      # today's behaviour, so the forgery gate stays exactly as strict as it
      # was for the surface it protects.
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
            message: "this is the account holder's browser page, not the Kiosk wire — " \
                     "it needs a signed-in session and a CSRF token from its own form",
            hint:    "assistants use the wire: GET #{request.base_url}/.well-known/kiosk.json " \
                     "for the register/login endpoints, then GET <endpoint>/schema " \
                     "(public) for the verbs this origin serves",
          },
        }
      end

      # Flash the sign-in prompt. The flash mixin is present on
      # ActionController::Base, but `request.flash` needs the flash
      # middleware in the stack — absent on a bare Rack host or Metal
      # dispatch — so a missing flash must not abort the redirect.
      def set_sign_in_flash
        flash[:alert] = "Please sign in to manage your linked assistants."
      rescue StandardError
        nil
      end

      # Devise convention: remember where the visitor was headed so login can
      # bounce them back to the manage page. Harmless if unused by the IdP.
      def store_return_location
        session["user_return_to"] = request.fullpath
      rescue StandardError
        nil
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
        # `lease_connection` for the reason `#update` records above.
        conn   = ::ActiveRecord::Base.lease_connection
        rows =
          begin
            sql, binds = bound_assistants_query(config, settled_spend: true)
            conn.exec_query(sql, "Kiosk bound assistants", binds)
          rescue ::ActiveRecord::StatementInvalid
            sql, binds = bound_assistants_query(config, settled_spend: false)
            conn.exec_query(sql, "Kiosk bound assistants", binds)
          end
        rows.to_a.map { |row| present(row) }
      end

      # `settled_spend:` toggles the correlated settlements subquery. false
      # (or a schema with no settlements table) yields a constant 0.
      #
      # Returns `[sql, binds]` together rather than the SQL alone: the two
      # branches declare DIFFERENT numbers of parameters (the spend-free one has
      # no window), and Postgres rejects a bind list that does not match the
      # statement it is sent with — so the statement and its arguments have to
      # be built in one place or the fallback breaks the moment a window is
      # configured.
      def bound_assistants_query(config, settled_spend:)
        window_days = settled_spend ? config.spending_cap_window_days&.to_i : nil
        sql = <<~SQL
          SELECT id, public_key, created_at, human_label, spending_cap_cents,
                 #{settled_cents_expr(config, settled_spend: settled_spend)} AS settled_cents
          FROM #{config.schema}.agents
          WHERE user_id = $1 AND revoked_at IS NULL
          ORDER BY created_at
        SQL
        [sql, [@identity.user_id, *Array(window_days)]]
      end

      # Correlated subquery summing this agent's settled spend from the
      # settlements table (COALESCE → 0 when it has settled nothing, or the
      # table has no rows), honouring spending_cap_window_days when set.
      #
      # WHETHER there is a window is a statement shape (no predicate at all
      # when there is none); HOW MANY DAYS is a value, so it is `$2` through
      # `make_interval` — the same treatment `executor.rb#settled_total_cents`
      # gives the identical expression.
      def settled_cents_expr(config, settled_spend:)
        return "0" unless settled_spend

        window = config.spending_cap_window_days ? "AND settled_at >= now() - make_interval(days => $2)" : ""
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
