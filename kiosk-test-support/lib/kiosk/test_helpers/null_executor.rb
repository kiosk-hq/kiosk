# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # In-memory executor that records every call without touching Postgres.
    # Lives here so the harness gems can run their own self-tests; providers
    # can also use it for unit-shaped tests that don't need real RLS.
    #
    # The real executor (`Kiosk::Server::TestExecutor`, ships with
    # `kiosk-server`) implements the same contract:
    #
    #   - `with_identity(identity, &block)` — opens a transaction-shaped
    #     scope where `current_*` GUCs are set from `identity`, yields, and
    #     rolls back. `identity` is a `Kiosk::Identity` or `nil`
    #     (anonymous). Implementations MAY choose to nest the call; the
    #     NullExecutor simply pushes onto a stack.
    #   - `query(sql)` — executes SQL under the current identity, returns rows.
    #   - `run_action(name, args)` / `pay_action(name, args)` — invokes
    #     a named Action / pay-Action; returns whatever the Action would.
    #   - `seed(table, attrs, count:)` — bulk-insert factory; runs as
    #     `system_role`, so it can populate tables under RLS.
    #
    # Pre-load deterministic results with `enqueue_query`, `enqueue_action`,
    # `enqueue_pay_action`, `enqueue_seed`. If no queued result, returns `[]`
    # for queries and `nil` for actions / seeds.
    #
    # Pre-load deterministic errors with `enqueue_error(:rls_denied)` /
    # `:quota_exceeded` — the next matching call raises.
    class NullExecutor
      # One recorded call. The journey DSL stamps `kind` (:query, :run_action,
      # :pay_action, :seed) plus the relevant `args`; `identity` is whatever
      # `with_identity` is currently scoping. `identity` is `nil` for
      # `as_anonymous` / unscoped calls.
      Call = Data.define(:kind, :args, :identity)

      attr_reader :calls, :identity_stack

      def initialize
        @calls          = []
        @identity_stack = []
        @queues         = Hash.new { |h, k| h[k] = [] }
        @errors         = Hash.new { |h, k| h[k] = [] }
      end

      # Push a scoped identity, yield, pop. Mirrors the request-shaped
      # transaction the real executor opens; we don't actually open any
      # transaction here — recording the identity stack is enough for
      # most journey-shaped self-tests.
      def with_identity(identity)
        @identity_stack.push(identity)
        yield
      ensure
        @identity_stack.pop
      end

      def query(sql)
        record(:query, { sql: sql })
        next_result_or_raise(:query)
      end

      def run_action(name, args)
        record(:run_action, { name: name, args: args })
        next_result_or_raise(:run_action)
      end

      def pay_action(name, args)
        record(:pay_action, { name: name, args: args })
        next_result_or_raise(:pay_action)
      end

      def seed(table, attrs, count:)
        record(:seed, { table: table, attrs: attrs, count: count })
        next_result_or_raise(:seed)
      end

      # --- Test-rig helpers ----------------------------------------------------

      # Queue a result for the next call of `kind`.
      def enqueue_query(result)       = @queues[:query]       << result
      def enqueue_action(result)      = @queues[:run_action]  << result
      def enqueue_pay_action(result)  = @queues[:pay_action]  << result
      def enqueue_seed(result)        = @queues[:seed]        << result

      # Queue an error for the next call of `kind`. `error` is :rls_denied,
      # :quota_exceeded, or a class.
      def enqueue_error(kind, error = :rls_denied)
        @errors[kind] << error
      end

      # Filter recorded calls. Handy for assertions:
      #   executor.calls_of(:run_action).map { |c| c.args[:name] }
      def calls_of(kind) = @calls.select { |c| c.kind == kind }

      # The current identity (top of stack) or `nil` if nothing scoped.
      def current_identity = @identity_stack.last

      private

      def record(kind, args)
        @calls << Call.new(kind: kind, args: args, identity: current_identity)
      end

      def next_result_or_raise(kind)
        if (err = @errors[kind].shift)
          raise resolve_error(err)
        end

        @queues[kind].empty? ? default_for(kind) : @queues[kind].shift
      end

      def default_for(kind)
        kind == :query ? [] : nil
      end

      def resolve_error(err)
        case err
        when :rls_denied      then Errors::RLSDenied
        when :quota_exceeded  then Errors::QuotaExceeded
        when Class            then err
        else raise ArgumentError, "unknown enqueued error #{err.inspect}"
        end
      end
    end
  end
end
