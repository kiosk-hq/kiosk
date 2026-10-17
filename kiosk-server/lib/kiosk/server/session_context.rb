# frozen_string_literal: true

require 'kiosk/server/errors'

module Kiosk
  module Server
    # The identity a wire request runs as. {#open} wraps the request in a
    # transaction and sets the principal's GUCs transaction-locally, for
    # operators who opt into RLS.
    class SessionContext
      # `SET LOCAL` with bound values; the third argument `true` is LOCAL.
      SET_GUC_SQL = 'SELECT set_config($1, $2, true)'

      KEY = :kiosk_server_session_context

      def self.open(connection:, identity:, &)
        new(connection: connection, identity: identity).open(&)
      end

      def self.current = Thread.current[KEY]

      def self.open? = !Thread.current[KEY].nil?

      # The identity the wire resolved. Raises outside a session, where a scope
      # built on it would otherwise match nothing.
      def self.identity
        return current.identity if open?

        raise Errors::Unauthenticated,
              'no Kiosk session is open. Wrap the call in ' \
              'Kiosk::Server::SessionContext.open(connection:, identity:), or pass the principal in.'
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
        stmts = principal_gucs
        return stmts unless Kiosk.configuration.enforce_db_role

        stmts + [["SET LOCAL ROLE #{quote_ident(Kiosk.configuration.app_role)}", []]]
      end

      private

      def apply_gucs
        guc_statements.each { |sql, binds| connection.exec_query(sql, 'Kiosk GUC', binds) }
      end

      # One `set_config` per principal field; role and agent_id only when present.
      def principal_gucs
        {
          Kiosk::GUC::USER_ID => identity.user_id,
          Kiosk::GUC::ROLE => identity.role,
          Kiosk::GUC::ACTOR => identity.actor,
          Kiosk::GUC::AGENT_ID => identity.agent_id
        }.filter_map do |field, value|
          next if !value && [Kiosk::GUC::ROLE, Kiosk::GUC::AGENT_ID].include?(field)

          guc_sql(Kiosk::GUC.for(Kiosk.configuration.guc_namespace, field), value)
        end
      end

      def guc_sql(name, value)
        [SET_GUC_SQL, [name.to_s, value.to_s]]
      end

      def quote_ident(name)
        name.to_s.split('.').map { |part| %("#{part.gsub('"', '""')}") }.join('.')
      end
    end
  end
end
