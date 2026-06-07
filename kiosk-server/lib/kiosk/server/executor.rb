# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"

module Kiosk
  module Server
    # Central dispatcher. Receives a verb (one of {VERBS}) + args +
    # {Kiosk::Identity} + a database connection. Opens {SessionContext}
    # (transaction + four `SET LOCAL` GUCs per spec §6.3), routes to the
    # appropriate verb method, returns {Result} on success or raises
    # {Errors::Base} subclass on failure.
    #
    # See design spec §5.4 «Server side» — this implements the
    # `Kiosk::ExecController#exec` pseudocode shown there, factored out of
    # the controller so it's testable without Rails.
    class Executor
      # Spec §5.1: the fixed six-verb wire surface.
      VERBS = %i[sql run pay schema help events].freeze

      def self.call(kind:, args:, identity:, connection:)
        new(connection: connection, identity: identity).call(kind: kind, args: args)
      end

      attr_reader :connection, :identity

      def initialize(connection:, identity:)
        raise Errors::Unauthenticated, "identity required" if identity.nil?

        @connection = connection
        @identity   = identity
      end

      def call(kind:, args:)
        verb = kind.to_sym
        unless VERBS.include?(verb)
          raise Errors::BadRequest.new(
            "Unknown verb: #{kind.inspect}",
            hint: "Valid verbs: #{VERBS.inspect}",
          )
        end

        SessionContext.open(connection: connection, identity: identity) do
          dispatch(verb, args)
        end
      end

      private

      def dispatch(verb, args)
        case verb
        when :sql    then verb_sql(args)
        when :run    then verb_run(args)
        when :pay    then verb_pay(args)
        when :schema then verb_schema(args)
        when :help   then verb_help(args)
        when :events then verb_events(args)
        end
      end

      # ─── sql ───────────────────────────────────────────────────────────

      def verb_sql(args)
        sql = string_arg(args, :sql)
        raise Errors::BadRequest, "args.sql required" if sql.nil? || sql.empty?

        rows = connection.execute(sql)
        Result.new(kind: :rows, payload: rows_to_array(rows))
      end

      # ─── run ───────────────────────────────────────────────────────────

      def verb_run(args)
        args = symbolize(args)
        name = args.delete(:name) || args.delete(:action)
        raise Errors::BadRequest, "args.name (action) required" if name.nil? || name.to_s.empty?

        handler = Actions.fetch(name)
        begin
          value = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          raise Errors::ActionFailed.new(
            "Action #{name.inspect} raised #{e.class}: #{e.message}",
            hint: "See server logs (action_log row) for full backtrace.",
          )
        end

        Result.new(kind: :value, payload: value)
      end

      # ─── stubs — land in follow-up releases ────────────────────────────

      def verb_pay(_args)
        raise NotImplementedError,
              "`pay` verb arrives with kiosk-pay-stripe (M4 in implementation plan)"
      end

      def verb_schema(_args)
        raise NotImplementedError,
              "`schema` verb arrives in a follow-up release (Postgres introspection)"
      end

      def verb_help(_args)
        raise NotImplementedError,
              "`help` verb arrives in a follow-up release (reads COMMENT ON TABLE/ACTION)"
      end

      def verb_events(_args)
        raise NotImplementedError,
              "`events` verb arrives in a follow-up release (NDJSON streaming per §5.8)"
      end

      # ─── helpers ───────────────────────────────────────────────────────

      def string_arg(args, key)
        return args.to_s if args.is_a?(String)

        h = symbolize(args)
        h[key]&.to_s
      end

      def symbolize(value)
        case value
        when Hash then value.transform_keys { |k| k.to_sym }
        when nil  then {}
        else value
        end
      end

      def rows_to_array(rows)
        # PG::Result responds to #to_a and yields Hash rows. Fake
        # connections in tests return Array<Hash> directly. Accept both.
        rows.respond_to?(:to_a) ? rows.to_a : Array(rows)
      end
    end
  end
end
