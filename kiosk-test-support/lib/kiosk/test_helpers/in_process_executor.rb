# frozen_string_literal: true

# Needs kiosk-server, which only a Rails host carries; this gem does not depend
# on it, so a test helper requires this file explicitly:
#   require "kiosk/test_helpers/in_process_executor"
#   Kiosk::TestHelpers.executor = Kiosk::TestHelpers::InProcessExecutor.new

require 'date'
require 'kiosk/server'
require 'kiosk/test_helpers/errors'
require 'kiosk/test_helpers/in_process_wire'

module Kiosk
  module TestHelpers
    # Runs the kiosk-test-support journey DSL against a real connection: each
    # identity scope sets the GUCs and always rolls back, and an RLS denial
    # surfaces as {Kiosk::TestHelpers::Errors::RLSDenied}. A verb goes through
    # its route, as an assistant calls it.
    class InProcessExecutor
      class NoScopeError < StandardError; end

      # Aborts the transaction, also on a connection double that ignores `ActiveRecord::Rollback`.
      class RollbackMarker < StandardError; end

      attr_reader :connection, :system_connection, :current_identity

      # `system_connection` seeds irrespective of RLS; it defaults to `connection`.
      # `app` is the Rack app a verb call goes through; it defaults to `Rails.application`.
      def initialize(connection: nil, system_connection: nil, app: nil)
        @connection        = connection        || default_connection
        @system_connection = system_connection || @connection
        @wire              = InProcessWire.new(app: app)
        @current_identity  = nil
        @scope_depth       = 0
      end

      def in_scope? = @scope_depth.positive?

      def with_identity(identity, &block)
        # Before touching scope state, so a rescued blockless call leaves it intact.
        raise ArgumentError, 'block required' unless block

        previous_identity = @current_identity
        @current_identity = identity
        @scope_depth     += 1
        begin
          call_rolled_back(identity, block)
        ensure
          @current_identity = previous_identity
          @scope_depth     -= 1
        end
      end

      def query(sql)
        require_scope!
        rescue_rls_denials do
          Sql.rows(connection.execute(sql))
        end
      end

      # A paginated answer returns its rows, as the caller receives them.
      def run_query(name, args) = call_verb(name, :query, args)

      def run_action(name, args) = call_verb(name, :action, args)

      # Settlement captures against a PSP, which an always-rolled-back scope cannot host.
      def pay_action(_name, _args)
        require_scope!
        raise NotImplementedError, 'pay is not exercised through the RLS journey DSL; ' \
                                   'settlement runs via Executor#verb_pay + a kiosk-pay-* provider'
      end

      def seed(table, attrs, count:)
        count.times.map do
          Sql.rows(system_connection.execute(Sql.insert(table, attrs))).first
        end
      end

      private

      def default_connection = ::ActiveRecord::Base.lease_connection

      # A refusal coded `rls_denied` surfaces as {Kiosk::TestHelpers::Errors::RLSDenied}.
      def call_verb(name, kind, args)
        require_scope!
        @wire.call(name, kind: kind, params: args, identity: current_identity)
      rescue Kiosk::Server::Errors::WireError => e
        raise Kiosk::TestHelpers::Errors::RLSDenied, e.message if e.code == 'rls_denied'

        raise
      end

      def require_scope!
        return if in_scope?

        raise NoScopeError,
              'call from inside as_user / as_agent / as_anonymous block (default-deny)'
      end

      # The block's result, or its error re-raised, after the transaction always rolls back.
      def call_rolled_back(identity, block)
        result = caught = nil
        rolled_back do
          apply_gucs(identity) if identity
          result, caught = capture { block.call(self) }
        end
        raise caught if caught

        result
      end

      def rolled_back
        connection.transaction do
          yield
          raise RollbackMarker
        end
      rescue RollbackMarker
        # The rollback is the point; the marker stops here.
      end

      def capture
        [yield, nil]
      rescue StandardError => e
        [nil, e]
      end

      def apply_gucs(identity)
        Kiosk::Server::SessionContext.new(connection: connection, identity: identity)
                                     .guc_statements
                                     .each { |sql, binds| connection.exec_query(sql, 'Kiosk GUC', binds) }
      end

      def rescue_rls_denials
        yield
      rescue StandardError => e
        raise Kiosk::TestHelpers::Errors::RLSDenied, e.message if Sql.rls_denial?(e)

        raise
      end

      # SQL literals, result rows, and the errors Postgres raises for an RLS denial.
      module Sql
        module_function

        def insert(table, attrs)
          cols       = attrs.keys
          values_sql = cols.map { |c| quote_value(attrs[c]) }.join(', ')
          col_sql    = cols.map { |c| quote_ident(c.to_s) }.join(', ')
          %(INSERT INTO #{quote_ident(table.to_s)} (#{col_sql}) ) +
            %(VALUES (#{values_sql}) RETURNING *)
        end

        # Result rows with symbol keys.
        def rows(result)
          return [] if result.nil?

          Array(result).map do |row|
            row.respond_to?(:transform_keys) ? row.transform_keys(&:to_sym) : row
          end
        end

        def rls_denial?(error)
          return true if rls_message?(error.message)

          cause = error.respond_to?(:cause) ? error.cause : nil
          cause && rls_message?(cause.message)
        end

        def rls_message?(message)
          return false if message.nil?

          message = message.to_s
          message.include?('row-level security') ||
            message.include?('violates row-level') ||
            message.include?('permission denied for table')
        end

        def quote_value(value)
          case value
          when nil                  then 'NULL'
          when true                 then 'TRUE'
          when false                then 'FALSE'
          when Numeric              then value.to_s
          # `getutc`: `Time#utc` mutates and `DateTime#utc` needs ActiveSupport.
          when Time, DateTime       then "'#{value.to_time.getutc.iso8601}'"
          when Date                 then "'#{value.iso8601}'"
          else
            "'#{value.to_s.gsub("'", "''")}'"
          end
        end

        def quote_ident(name)
          name.to_s.split('.').map { |part| %("#{part.gsub('"', '""')}") }.join('.')
        end
      end
    end
  end
end
