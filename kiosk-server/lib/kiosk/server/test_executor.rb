# frozen_string_literal: true

# Test-time only; required explicitly:
#   Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new

require "date"
require "active_record"
require "kiosk/server/current_request"
require "kiosk/server/queries"
require "kiosk/server/result"
require "kiosk/test_helpers/errors"

module Kiosk
  module Server
    # Runs the kiosk-test-support journey DSL against a real connection: each
    # identity scope sets the GUCs and always rolls back, and an RLS denial
    # surfaces as {Kiosk::TestHelpers::Errors::RLSDenied}.
    class TestExecutor
      class NoScopeError < StandardError; end

      # Aborts the transaction, also on a connection double that ignores `ActiveRecord::Rollback`.
      class RollbackMarker < StandardError; end

      attr_reader :connection, :system_connection

      # `system_connection` seeds irrespective of RLS; it defaults to `connection`.
      def initialize(connection: nil, system_connection: nil)
        @connection        = connection        || default_connection
        @system_connection = system_connection || @connection
        @current_identity  = nil
        @scope_depth       = 0
      end

      def current_identity = @current_identity

      def in_scope? = @scope_depth.positive?

      def with_identity(identity, &block)
        # Before touching scope state, so a rescued blockless call leaves it intact.
        raise ArgumentError, "block required" unless block

        previous_identity = @current_identity
        @current_identity = identity
        @scope_depth     += 1
        result = nil
        caught = nil

        begin
          begin
            connection.transaction do
              apply_gucs(identity) if identity
              begin
                result = block.call(self)
              rescue StandardError => e
                caught = e
              end
              raise RollbackMarker
            end
          rescue RollbackMarker
            # The rollback is the point; the marker stops here.
          end

          raise caught if caught
          result
        ensure
          @current_identity = previous_identity
          @scope_depth     -= 1
        end
      end

      def query(sql)
        require_scope!
        rescue_rls_denials do
          normalize_rows(connection.execute(sql))
        end
      end

      # A paginated answer returns its rows, as the caller receives them.
      def run_query(name, args)
        require_scope!
        query_handler = Kiosk::Server::Queries.fetch(name)
        rescue_rls_denials do
          answer = Kiosk::Server::CurrentRequest.with(identity: current_identity) do
            query_handler.call(args)
          end
          answer.is_a?(Kiosk::Server::Page) ? answer.rows : answer
        end
      end

      def run_action(name, args)
        require_scope!
        action = Kiosk::Server::Actions.fetch(name)
        rescue_rls_denials do
          Kiosk::Server::CurrentRequest.with(identity: current_identity) do
            action.call(args)
          end
        end
      end

      # Settlement captures against a PSP, which an always-rolled-back scope cannot host.
      def pay_action(_name, _args)
        require_scope!
        raise NotImplementedError, "pay is not exercised through the RLS journey DSL; " \
                                   "settlement runs via Executor#verb_pay + a kiosk-pay-* provider"
      end

      def seed(table, attrs, count:)
        cols = attrs.keys
        count.times.map do
          values_sql = cols.map { |c| quote_value(attrs[c]) }.join(", ")
          col_sql    = cols.map { |c| quote_ident(c.to_s) }.join(", ")
          sql = %(INSERT INTO #{quote_ident(table.to_s)} (#{col_sql}) ) +
                %(VALUES (#{values_sql}) RETURNING *)
          normalize_rows(system_connection.execute(sql)).first
        end
      end

      private

      def default_connection = ::ActiveRecord::Base.lease_connection

      def require_scope!
        return if in_scope?

        raise NoScopeError,
          "call from inside as_user / as_agent / as_anonymous block (default-deny)"
      end

      def apply_gucs(identity)
        SessionContext.new(connection: connection, identity: identity)
                      .guc_statements
                      .each { |sql, binds| connection.exec_query(sql, "Kiosk GUC", binds) }
      end

      def normalize_rows(result)
        return [] if result.nil?

        Array(result).map do |row|
          row.respond_to?(:transform_keys) ? row.transform_keys(&:to_sym) : row
        end
      end

      def rescue_rls_denials
        yield
      rescue StandardError => e
        raise Kiosk::TestHelpers::Errors::RLSDenied, e.message if rls_denial?(e)
        raise
      end

      def rls_denial?(error)
        return true if message_matches_rls?(error.message)

        cause = error.respond_to?(:cause) ? error.cause : nil
        cause && message_matches_rls?(cause.message)
      end

      def message_matches_rls?(message)
        return false if message.nil?
        message = message.to_s
        message.include?("row-level security") ||
          message.include?("violates row-level") ||
          message.include?("permission denied for table")
      end

      def quote_value(value)
        case value
        when nil                  then "NULL"
        when true                 then "TRUE"
        when false                then "FALSE"
        when Numeric              then value.to_s
        # `getutc`: `Time#utc` mutates and `DateTime#utc` needs ActiveSupport.
        when Time, DateTime       then "'#{value.to_time.getutc.iso8601}'"
        when Date                 then "'#{value.iso8601}'"
        else
          "'#{value.to_s.gsub("'", "''")}'"
        end
      end

      def quote_ident(name)
        name.to_s.split(".").map { |part| %("#{part.gsub('"', '""')}") }.join(".")
      end
    end
  end
end
