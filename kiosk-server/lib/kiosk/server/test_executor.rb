# frozen_string_literal: true

# Not auto-loaded by `require "kiosk/server"` — this file is test-time
# infrastructure and shouldn't appear in production boot. Users wire it
# up explicitly in their spec / test helper:
#
#   # spec/spec_helper.rb
#   require "kiosk/server"
#   require "kiosk/server/test_executor"
#   require "kiosk/rls_rspec"  # OR kiosk/rls_minitest
#
#   Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
require "date"
require "active_record"
require "kiosk/server/current_request"
require "kiosk/test_helpers/errors"

module Kiosk
  module Server
    # Bridges the Kiosk::TestHelpers::Journey DSL (defined in the
    # kiosk-test-support gem) to a real ActiveRecord connection, so that
    # provider apps can write RLS journey tests against actual Postgres
    # policies. Satisfies the contract documented in
    # {Kiosk::TestHelpers::NullExecutor}'s docstring.
    #
    # Each `with_identity(...)` opens a transaction, sets the four
    # canonical GUCs via {SessionContext}, yields, and **always rolls
    # back** — tests stay hermetic across runs even when they INSERT
    # data inside the scope. The block's return value is preserved.
    #
    # `query` / `run_action` execute inside the active scope and surface
    # Postgres RLS denials as {Kiosk::TestHelpers::Errors::RLSDenied} so
    # the `be_rls_denied` / `assert_rls_denied` matchers can catch them.
    #
    # `seed` runs through an optional `system_connection` (which the host
    # configures to bypass RLS via either `BYPASSRLS` role or `SET LOCAL
    # row_security = off`) so tests can populate tables that the
    # under-test identity wouldn't otherwise be able to write to.
    #
    # @example Wire in spec_helper.rb
    #   require "kiosk/server"
    #   require "kiosk/server/test_executor"
    #   require "kiosk/rls_rspec"
    #
    #   Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
    #
    # @example A journey test
    #   describe "appointments RLS", type: :kiosk_journey do
    #     it "alice sees her appointments, not bob's" do
    #       kiosk_seed(:appointments, owner: alice, salon_id: 1)
    #       kiosk_seed(:appointments, owner: bob,   salon_id: 1)
    #
    #       as_user(alice) do
    #         expect(query("SELECT COUNT(*) FROM appointments").first[:count]).to eq(1)
    #       end
    #     end
    #
    #     it "alice cannot INSERT for bob" do
    #       expect {
    #         as_user(alice) do
    #           query(%(INSERT INTO appointments(user_id,salon_id,slot)
    #                   VALUES('#{bob.id}',1,NOW())))
    #         end
    #       }.to be_rls_denied
    #     end
    #   end
    class TestExecutor
      # Raised when a `query` / `run_action` lands outside any
      # `with_identity` scope. The Journey DSL refuses to allow this by
      # default; see {Kiosk::TestHelpers::Journey#query}.
      class NoScopeError < StandardError; end

      # Internal marker that signals "abort this transaction" both for
      # ActiveRecord and for connection doubles that don't catch
      # `ActiveRecord::Rollback`. Caught by the with_identity rescue and
      # never propagated to the caller.
      class RollbackMarker < StandardError; end

      attr_reader :connection, :system_connection

      # @param connection [#execute, #transaction] RLS-protected app
      #   connection. Defaults to `ActiveRecord::Base.lease_connection` when
      #   Rails is loaded.
      # @param system_connection [#execute, #transaction] connection
      #   used by {#seed} to populate tables irrespective of RLS.
      #   Defaults to `connection` (sufficient when the role owns the
      #   tables or has `BYPASSRLS`).
      def initialize(connection: nil, system_connection: nil)
        @connection        = connection        || default_connection
        @system_connection = system_connection || @connection
        @current_identity  = nil
        @scope_depth       = 0
      end

      # @return [Kiosk::Identity, nil] identity at the top of the
      #   `with_identity` stack; `nil` for `as_anonymous` or when not in
      #   any scope.
      def current_identity = @current_identity

      # @return [Boolean] whether we're currently inside a with_identity
      #   block — used by {#query} / {#run_action} to enforce
      #   default-deny behaviour.
      def in_scope? = @scope_depth.positive?

      # Open a hermetic identity scope. Sets the four GUCs from
      # `identity`, yields, ROLLS BACK unconditionally. Returns the
      # block's return value; re-raises any exception the block threw
      # after the rollback completes.
      def with_identity(identity, &block)
        # Guard BEFORE touching any scope state. If this raised after
        # incrementing @scope_depth, the ensure below would still fire and
        # decrement it (and clobber @current_identity) — corrupting an
        # enclosing scope when a blockless call is rescued inside it.
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
            # Expected. AR's transaction caught the marker → rolled back +
            # re-raised; we swallow here. For connection doubles that don't
            # swallow Rollback themselves, this rescue is the cleanup point.
          end

          raise caught if caught
          result
        ensure
          # Only unwind scope state we actually set up above — reached solely
          # when the block guard passed, so an enclosing scope is preserved.
          @current_identity = previous_identity
          @scope_depth     -= 1
        end
      end

      # Execute a SQL statement inside the active scope. Returns rows as
      # `Array<Hash>` with symbolised keys.
      def query(sql)
        require_scope!
        rescue_rls_denials do
          normalize_rows(connection.execute(sql))
        end
      end

      # Invoke an Action by name within the active scope. Returns
      # whatever the Action returns.
      #
      # `CurrentRequest.with` makes the scope's identity visible to a handler
      # registered as a controller action (`kind :action` on a Kiosk::Handler), which reads
      # it as `kiosk_identity`. There is no Rack env here — a journey test is not
      # an HTTP request — so such a handler sees no request headers, exactly as
      # its docstring says.
      def run_action(name, args)
        require_scope!
        action = Kiosk::Server::Actions.fetch(name)
        rescue_rls_denials do
          Kiosk::Server::CurrentRequest.with(identity: current_identity) do
            action.call(args)
          end
        end
      end

      # `pay` is deliberately unsupported in the RLS journey DSL: the real
      # settlement path (Executor#verb_pay + kiosk-pay-stripe) captures against
      # a live PSP and manages its own transaction boundaries, which the
      # always-rolls-back journey scope cannot host. Journey tests exercise
      # query / run_action against RLS policies, not payment capture.
      def pay_action(_name, _args)
        require_scope!
        raise NotImplementedError, "pay is not exercised through the RLS journey DSL; " \
                                   "settlement runs via Executor#verb_pay + a kiosk-pay-* provider"
      end

      # Bulk-insert `count` rows into `table` with the supplied `attrs`.
      # Runs through `system_connection` (which should bypass RLS), so
      # tests can populate tables under any identity.
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

      # `lease_connection`, not `connection` (K-782): the LAST
      # `ActiveRecord::Base.connection` in this gem. It is soft-deprecated in
      # Rails 8.1 and RAISES under `permanent_connection_checkout =
      # :disallowed`, so a host on the new default could not build a
      # TestExecutor without injecting a connection by hand — and one survivor
      # is enough to keep teaching the idiom the rest of the engine just gave
      # up. Not `with_connection`: this object holds its connection across many
      # `as_user`/`as_agent` blocks, each of which opens its own GUC-scoped
      # transaction on it, so the connection outlives any single block.
      def default_connection = ::ActiveRecord::Base.lease_connection

      def require_scope!
        return if in_scope?

        raise NoScopeError,
          "call from inside as_user / as_agent / as_anonymous block (default-deny)"
      end

      # `[sql, binds]` pairs through `exec_query` — the identity GUCs travel as
      # bind parameters (K-789), so this mirrors `SessionContext#apply_gucs`
      # rather than re-implementing it.
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

      # Surface Postgres RLS denials as the canonical test-DSL error so
      # `be_rls_denied` / `assert_rls_denied` can catch them. Match both
      # the AR-wrapper message and any underlying PG cause for safety
      # across adapter versions.
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
        # `to_time.getutc` is non-mutating and works for plain Time AND plain
        # DateTime (which has no #utc). `Time#utc` mutates the caller's object
        # and `DateTime#utc` raises NoMethodError outside ActiveSupport.
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
