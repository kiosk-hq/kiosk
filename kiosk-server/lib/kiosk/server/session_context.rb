# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # The identity a wire request runs as. {#open} wraps the request in a
    # transaction and sets the principal's GUCs transaction-locally, for
    # operators who opt into RLS.
    class SessionContext
      # `SET LOCAL` with bound values; the third argument `true` is LOCAL.
      SET_GUC_SQL = "SELECT set_config($1, $2, true)"

      KEY = :kiosk_server_session_context

      def self.open(connection:, identity:, &block)
        new(connection: connection, identity: identity).open(&block)
      end

      def self.current = Thread.current[KEY]

      def self.open? = !Thread.current[KEY].nil?

      # The identity the wire resolved. Raises outside a session, where a scope
      # built on it would otherwise match nothing.
      def self.identity
        return current.identity if open?

        raise Errors::Unauthenticated,
              "no Kiosk session is open. Wrap the call in " \
              "Kiosk::Server::SessionContext.open(connection:, identity:), or pass the principal in."
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

      def guc_statements
        ns    = Kiosk.configuration.guc_namespace
        stmts = [
          guc_sql(Kiosk::GUC.for(ns, Kiosk::GUC::USER_ID),  identity.user_id),
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

      def quote_ident(name)
        name.to_s.split(".").map { |part| %("#{part.gsub('"', '""')}") }.join(".")
      end
    end
  end
end
