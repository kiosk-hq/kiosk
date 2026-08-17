# frozen_string_literal: true

module Kiosk
  module Server
    # Wraps a database connection + {Kiosk::Identity}, opens a transaction,
    # sets the four canonical Postgres GUCs (`app.current_user_id` etc.,
    # transaction-local), yields the block, releases on commit/rollback.
    #
    # Connection-agnostic: works with anything responding to
    # `#exec_query(sql, name, binds)` and `#transaction { ... }`.
    # `ActiveRecord::Base.lease_connection` fits (and is what
    # `wire_controller.rb` hands it); in tests a `FakeConnection` recording
    # calls works.
    #
    # The transaction is the natural scope for a transaction-local GUC —
    # values vanish at COMMIT/ROLLBACK, so no leak between requests on a
    # shared connection pool (mitigation for «`SET LOCAL` mistakes
    # leak across requests»).
    class SessionContext
      # `SET LOCAL <name> = <value>` with the value BOUND. Postgres accepts no
      # bind parameters in `SET`, so the engine used to build this statement
      # with a hand-rolled `quote_literal` — the last value escaped by hand in
      # this gem after K-654 and K-782, and the one value the whole system
      # trusts (K-789). `set_config(name, value, is_local)` is the function
      # spelling of the same statement and takes both halves as binds; the
      # third argument `true` IS `LOCAL`.
      #
      # Proven equivalent against a real Postgres, not assumed — see
      # `session_context_spec.rb`'s real-database examples: identical value
      # inside the transaction, gone after COMMIT and after ROLLBACK, GUC names
      # case-folded the same way, and no `quote_ident` needed for
      # `app.current_role` (a reserved keyword that `SET` could not parse
      # unquoted, which is why the name was quoted segment-by-segment before).
      #
      # THE ONE OBSERVABLE DIFFERENCE, recorded rather than glossed: run
      # OUTSIDE a transaction, `SET LOCAL` logs `WARNING: SET LOCAL can only be
      # used in transaction blocks` and does nothing, while `set_config(…,
      # true)` does nothing silently. `#open` wraps every call in
      # `connection.transaction`, so no shipped path can reach it — but the
      # free diagnostic for a connection double whose `#transaction` does not
      # open one is gone.
      SET_GUC_SQL = "SELECT set_config($1, $2, true)"
      # Open a session, yield self, clean up.
      #
      # @yield [SessionContext]
      def self.open(connection:, identity:, &block)
        new(connection: connection, identity: identity).open(&block)
      end

      attr_reader :connection, :identity

      def initialize(connection:, identity:)
        @connection = connection
        @identity   = identity
      end

      def open
        connection.transaction do
          apply_gucs
          yield self
        end
      end

      # The statements this context issues, as `[sql, binds]` pairs — the two
      # arguments `#exec_query` takes, and the same shape the specs' `bound`
      # helper reads. Useful in tests + documentation; `#apply_gucs` runs
      # exactly this list and nothing else, so it cannot drift from what the
      # session really does.
      #
      # When +enforce_db_role+ is set, appends a <tt>SET LOCAL ROLE</tt>
      # statement as the final entry so the session drops to the app role after
      # the GUCs are applied (reverts at COMMIT/ROLLBACK — same transaction
      # scoping guarantee as the GUCs). That one carries an IDENTIFIER, not a
      # value, so it has no bind and keeps `quote_ident`.
      def guc_statements
        ns    = Kiosk.configuration.guc_namespace
        stmts = [
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::USER_ID),  identity.user_id),
          # Role-less identities set no role GUC — RLS/app checks
          # reading it via current_setting(..., true) see NULL.
          (guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::ROLE),    identity.role) if identity.role),
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::ACTOR),    identity.actor),
          (guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::AGENT_ID), identity.agent_id) if identity.agent_id),
        ].compact

        if Kiosk.configuration.enforce_db_role
          stmts + [["SET LOCAL ROLE #{quote_ident(Kiosk.configuration.app_role)}", []]]
        else
          stmts
        end
      end

      private

      def apply_gucs
        guc_statements.each { |sql, binds| connection.exec_query(sql, "Kiosk GUC", binds) }
      end

      def guc_sql(name, value)
        [SET_GUC_SQL, [name.to_s, value.to_s]]
      end

      # Quote a `SET LOCAL ROLE` identifier. GUC NAMES no longer need this —
      # `set_config` takes the name as a bound string, and Postgres folds it
      # exactly as it folds an unquoted identifier, so the reserved-keyword
      # collision that forced segment-by-segment quoting (`current_role`) is
      # gone with the `SET` statement that had it.
      def quote_ident(name)
        name.to_s.split(".").map { |part| %("#{part.gsub('"', '""')}") }.join(".")
      end
    end
  end
end
