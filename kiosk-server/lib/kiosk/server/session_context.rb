# frozen_string_literal: true

require "kiosk/server/errors"

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
      # bind parameters in `SET`, and spelling it that way would leave the one
      # value the whole system trusts escaped by hand, through a rolled
      # `quote_literal`. `set_config(name, value, is_local)` is the function
      # spelling of the same statement and takes both halves as binds; the
      # third argument `true` IS `LOCAL`.
      #
      # Proven equivalent against a real Postgres, not assumed — see
      # `session_context_spec.rb`'s real-database examples: identical value
      # inside the transaction, gone after COMMIT and after ROLLBACK, GUC names
      # case-folded the same way, and no `quote_ident` needed for
      # `app.current_role` (a reserved keyword that `SET` itself cannot parse
      # unquoted).
      #
      # THE ONE OBSERVABLE DIFFERENCE, recorded rather than glossed: run
      # OUTSIDE a transaction, `SET LOCAL` logs `WARNING: SET LOCAL can only be
      # used in transaction blocks` and does nothing, while `set_config(…,
      # true)` does nothing silently. `#open` wraps every call in
      # `connection.transaction`, so no shipped path can reach it — but the
      # free diagnostic for a connection double whose `#transaction` does not
      # open one is gone.
      SET_GUC_SQL = "SELECT set_config($1, $2, true)"

      # Where {.current} is parked for the duration of one open session.
      #
      # `Thread.current[]` is FIBER-local and the set/restore is block-scoped —
      # the same carrier and the same reasoning as {CurrentRequest}, and for the
      # same reason it is not an `ActiveSupport::CurrentAttributes`: this class
      # is also used from a plain rake task, from the RLS journey DSL and from
      # unit specs, none of which runs the Rails executor that would reset one.
      KEY = :kiosk_server_session_context

      # Open a session, yield self, clean up.
      #
      # @yield [SessionContext]
      def self.open(connection:, identity:, &block)
        new(connection: connection, identity: identity).open(&block)
      end

      # The session open on this thread, or nil.
      #
      # @return [SessionContext, nil]
      def self.current = Thread.current[KEY]

      # @return [Boolean] whether a Kiosk session — and therefore the
      #   `<guc_namespace>.current_user_id` GUC — is in effect right here.
      def self.open? = !Thread.current[KEY].nil?

      # ── THE GUARD AN IDENTITY-SCOPED SCOPE CALLS BEFORE IT BUILDS ITS WHERE ─
      #
      # `where(user_id: kiosk.current_user_id())` is the one predicate an
      # operator writes in the terms an RLS policy is written in, and the
      # database function behind it is a `current_setting(…, true)` read:
      # `missing_ok`, so with no GUC set it is NULL, `user_id = NULL` matches
      # nothing, and the caller gets an EMPTY RELATION with no exception and no
      # log line. Empty is the dangerous answer — it reads exactly like correct
      # isolation, and every negative assertion over it passes.
      #
      # No served request can reach that state ({Executor} refuses to build
      # without an identity and this class sets the GUC from it), so what this
      # guard is for is the caller OFF the wire: a console, a rake task, a seed,
      # a copy of the pattern into a background job later. Those get an
      # exception naming the remedy instead of a plausible zero.
      #
      # IT ASKS RUBY, NOT POSTGRES, AND THAT IS DELIBERATE. A `SELECT
      # <schema>.current_user_id()` here would be a second round trip on every
      # owner-scoped read, on a path that runs tens of times per request, to
      # re-derive a fact this process already knows. The database function keeps
      # its NULL semantics untouched, which is not a detail: an RLS policy
      # returning no rows is how RLS HIDES rows, and a function that raised
      # instead would turn every hidden row into a 500.
      #
      # The class is {Errors::Unauthenticated} — 401, `unauthenticated`, already
      # in the spec's closed `code` vocabulary — so that if a request path ever
      # does reach it the wire answers a typed problem document rather than a
      # 500, and fails closed. No new code is minted for it.
      #
      # @raise [Errors::Unauthenticated] when no session is open
      # @return [void]
      def self.require_open!
        return if open?

        raise Errors::Unauthenticated,
              "no Kiosk session is open, so the current-principal predicate would be " \
              "`= NULL` and this relation would answer nothing at all. On the wire the " \
              "engine opens one for you; off it — a console, a rake task, a seed — wrap " \
              "the call in Kiosk::Server::SessionContext.open(connection:, identity:), " \
              "or take the principal as an argument instead of reading it from the session."
      end

      attr_reader :connection, :identity

      def initialize(connection:, identity:)
        @connection = connection
        @identity   = identity
      end

      def open
        connection.transaction do
          apply_gucs
          previous = Thread.current[KEY]
          Thread.current[KEY] = self
          begin
            yield self
          ensure
            Thread.current[KEY] = previous
          end
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

      # Quote a `SET LOCAL ROLE` identifier — the ONLY place this is needed.
      # GUC NAMES do not go through it: `set_config` takes the name as a bound
      # string and Postgres folds it exactly as it folds an unquoted
      # identifier, so a reserved-keyword name (`current_role`) needs no
      # segment-by-segment quoting.
      def quote_ident(name)
        name.to_s.split(".").map { |part| %("#{part.gsub('"', '""')}") }.join(".")
      end
    end
  end
end
