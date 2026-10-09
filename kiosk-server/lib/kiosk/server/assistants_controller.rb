# frozen_string_literal: true

require "action_controller"
require "kiosk/server/account_binding"
require "kiosk/server/link_code"
require "kiosk/server/signing_key"

module Kiosk
  module Server
    # «Link an assistant» page: a signed-in account holder lists, labels,
    # links and unlinks their assistants. Host views override
    # app/views/kiosk/server/assistants/show.html.erb.
    class AssistantsController < ::ActionController::Base
      include AccountHolderGate
      include BindingModuleGate
      prepend_before_action :refuse_unserved_binding

      SIGN_IN_PROMPT = "Sign in to your account first to manage linked assistants."
      SIGN_IN_ALERT  = "Please sign in to manage your linked assistants."

      # Host app view paths come first, so an operator's templates win.
      append_view_path File.expand_path("../../../app/views", __dir__)
      layout false

      # A JSON caller without a CSRF token is an assistant at the wrong door:
      # point it at the wire. Browser requests re-raise untouched.
      rescue_from ::ActionController::InvalidAuthenticityToken do |error|
        raise error unless json_request?

        render json: wrong_door_envelope, status: :unprocessable_entity
      end

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
        @notice = "Assistant unlinked — its key no longer signs in."
        render_page
      rescue Errors::Base => e
        @error = e.message
        render_page(status: e.http_status)
      end

      # Edits a bound assistant's label and/or spending cap (blank cap → unlimited).
      def update
        return unless require_account_holder!(prompt: SIGN_IN_PROMPT, flash_alert: SIGN_IN_ALERT)

        conn = ::ActiveRecord::Base.lease_connection

        # Column names are literals; every value, above all the free-text label, is a bind.
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
          # The ownership predicate is the security boundary: `agent_id` from the caller, `user_id` from the session.
          binds.concat([params[:agent_id].to_s, @identity.user_id, Kiosk.current_issuer])
          conn.exec_query(<<~SQL, "Kiosk assistant update", binds)
            UPDATE #{Kiosk.configuration.schema}.agents
            SET #{assignments.join(", ")}
            WHERE id = $#{binds.size - 2}
              AND user_id = $#{binds.size - 1}
              AND issuer = $#{binds.size}
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
        # Without a `config.spending_cap` seam the saved cap binds nothing; the page says so.
        @spending_cap_enforced = !Kiosk.configuration.spending_cap.nil?
        @page_path = request.path.sub(%r{/(link|unlink|update)\z}, "")
        render :show, status: status
      end

      # An explicit JSON Accept or a JSON body; anything ambiguous counts as a browser.
      def json_request?
        return true if request.format.json?

        !!request.content_mime_type&.json?
      rescue StandardError
        false
      end

      # Not a problem document: this page is not a wire endpoint.
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

      # The holder's live agents with their settled spend. Without a settlements
      # table (no payment surface) the spend falls back to 0.
      def bound_assistants
        config = Kiosk.configuration
        conn   = ::ActiveRecord::Base.lease_connection
        rows =
          begin
            sql, binds = bound_assistants_query(config, settled_spend: true)
            conn.exec_query(sql, "Kiosk bound assistants", binds)
          rescue ::ActiveRecord::StatementInvalid => e
            raise unless missing_table?(e)

            sql, binds = bound_assistants_query(config, settled_spend: false)
            conn.exec_query(sql, "Kiosk bound assistants", binds)
          end
        rows.to_a.map { |row| present(row) }
      end

      # By class name, so this file does not load `PG`.
      def missing_table?(error)
        error.cause&.class&.name == "PG::UndefinedTable"
      end

      # Returns `[sql, binds]` together: the two branches take different bind counts.
      def bound_assistants_query(config, settled_spend:)
        window_days = settled_spend ? config.spending_cap_window_days&.to_i : nil
        sql = <<~SQL
          SELECT id, public_key, created_at, human_label, spending_cap_cents,
                 #{settled_cents_expr(config, settled_spend: settled_spend)} AS settled_cents
          FROM #{config.schema}.agents
          WHERE user_id = $1 AND issuer = $2 AND revoked_at IS NULL
          ORDER BY created_at
        SQL
        [sql, [@identity.user_id, Kiosk.current_issuer, *Array(window_days)]]
      end

      # This agent's settled spend, within `spending_cap_window_days` when set.
      def settled_cents_expr(config, settled_spend:)
        return "0" unless settled_spend

        window = config.spending_cap_window_days ? "AND settled_at >= now() - make_interval(days => $3)" : ""
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
