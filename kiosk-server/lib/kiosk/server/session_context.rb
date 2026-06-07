# frozen_string_literal: true

module Kiosk
  module Server
    # Wraps a database connection + {Kiosk::Identity}, opens a transaction,
    # sets the four canonical Postgres GUCs (`SET LOCAL app.current_user_id`
    # etc. per spec §6.3), yields the block, releases on commit/rollback.
    #
    # Connection-agnostic: works with anything responding to `#execute(sql)`
    # and `#transaction { ... }`. `ActiveRecord::Base.connection` fits; in
    # tests a `FakeConnection` recording calls works.
    #
    # The transaction is the natural scope for `SET LOCAL` — values vanish
    # at COMMIT/ROLLBACK, so no leak between requests on a shared
    # connection pool (per spec §13 mitigation for «`SET LOCAL` mistakes
    # leak across requests»).
    class SessionContext
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

      # Just the SQL statements that would be issued, useful in tests +
      # documentation.
      def guc_statements
        ns = Kiosk.configuration.guc_namespace
        [
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::USER_ID),  identity.user_id),
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::ROLE),     identity.role),
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::ACTOR),    identity.actor),
          (guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::AGENT_ID), identity.agent_id) if identity.agent_id),
        ].compact
      end

      private

      def apply_gucs
        guc_statements.each { |sql| connection.execute(sql) }
      end

      def guc_sql(name, value)
        "SET LOCAL #{name} = #{quote_literal(value.to_s)}"
      end

      def quote_literal(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end
end
