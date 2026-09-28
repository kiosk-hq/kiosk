# frozen_string_literal: true

module Kiosk
  module Server
    # Durable adapters for the per-identity event tail.
    #
    # The DEFAULT store is {Kiosk::Server::EventStore} — a Hash + Mutex living
    # in ONE process. That is the TEST implementation and a development
    # convenience, and it is the wrong thing to deploy. A deployed origin sets:
    #
    #   Kiosk.configure do |c|
    #     c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
    #   end
    #
    # which `rails generate kiosk:install` writes into the initializer. An origin
    # that declares a topic and leaves the default in place is refused at boot by
    # {Kiosk::Server::Engine.ephemeral_event_store_error}, and that message is
    # where the reason lives.
    #
    # Naming follows {PowSpentStores}: the in-process store is the top-level
    # {EventStore} rather than an `EventStores::InMemory`, because the constant
    # is named in operator initializers and in the suite.
    module EventStores
      # Event tail backed by the `<schema>.events` table
      # ({SchemaDefinitions.events_sql}), shared by every process pointed at the
      # same database. SQL with BIND PARAMETERS through the host's
      # `::ActiveRecord::Base.lease_connection` — the same access idiom as
      # {PowSpentStores::ActiveRecord}, so no model class is defined and
      # satellite neutrality holds.
      class ActiveRecord
        # The published retention FLOOR: an origin serves at least this much
        # history per identity. Long enough for a subscription topic — a delivery
        # window, or a shared list somebody adds to tomorrow — and not for a
        # reconnect alone.
        DEFAULT_RETENTION_HOURS = 24

        # Seconds between opportunistic retention sweeps. Bounds table growth
        # only; nothing about correctness depends on a row being gone on time,
        # so it is throttled hard rather than run on every append.
        DEFAULT_PRUNE_INTERVAL = 300

        # There is deliberately NO row-count ceiling. On a busy subject a count
        # binds long before the time does, so it would silently become the real
        # retention and the published floor would be a number no operator meets.
        # A ceiling added as a defence against one identity filling the table has
        # to be large enough that the TIME is what binds in ordinary use.
        def initialize(retention_hours: DEFAULT_RETENTION_HOURS,
                       prune_interval: DEFAULT_PRUNE_INTERVAL)
          @retention_hours = retention_hours
          @prune_interval  = prune_interval
          @last_prune_at   = 0
          @mutex           = Mutex.new
        end

        # @param identity_key [String] a user_id
        # @param event [Hash] string-keyed, WITHOUT "id"
        # @return [Integer] the id the sequence assigned
        def append(identity_key, event)
          prune_if_due!

          sql = <<~SQL
            INSERT INTO #{table} (identity_key, topic, subject, occurred_at, data)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id
          SQL
          rows = connection.exec_query(
            sql, "Kiosk events append",
            [identity_key.to_s, event["topic"], event["subject"],
             event["occurred_at"], JSON.generate(event["data"])],
          ).to_a
          rows.first["id"].to_i
        end

        # @return [Array<Hash>] this identity's events with a greater id, ascending
        def since(identity_key, id)
          sql = <<~SQL
            SELECT id, topic, subject, occurred_at, data
            FROM #{table}
            WHERE identity_key = $1 AND id > $2
            ORDER BY id ASC
          SQL
          connection.exec_query(sql, "Kiosk events since", [identity_key.to_s, id.to_i])
                    .to_a.map { |row| to_event(row) }
        end

        # @return [Integer] the origin's current maximum id, 0 on a fresh origin
        def head
          row = connection.exec_query(
            %(SELECT COALESCE(MAX(id), 0) AS head FROM #{table}), "Kiosk events head"
          ).to_a.first
          row["head"].to_i
        end

        # "I cannot prove you saw everything." True when rows between the
        # caller's cursor and what is still retained have been swept.
        #
        # TWO clauses, and the second is what keeps a cursor at head honest: if
        # the origin holds nothing newer than the caller's id, there is nothing
        # they could have missed, whatever the floor says. Without it a caller
        # fully caught up on a swept origin would be told to re-read.
        def truncated?(_identity_key, id)
          row = connection.exec_query(
            %(SELECT COALESCE(MIN(id), 0) AS floor, COALESCE(MAX(id), 0) AS head FROM #{table}),
            "Kiosk events floor",
          ).to_a.first
          floor = row["floor"].to_i
          return false if row["head"].to_i <= id.to_i
          return false if floor.zero?

          floor > id.to_i + 1
        end

        # Delete everything older than the retention window. Called
        # opportunistically by {#append} at most once per +prune_interval+ per
        # process; also safe to schedule as a periodic job instead.
        def prune!
          connection.exec_query(
            %(DELETE FROM #{table} WHERE created_at < now() - ($1 || ' hours')::interval),
            "Kiosk events prune", [@retention_hours.to_s],
          )
          nil
        end

        private

        # The five closed members of the wire's event, string-keyed, exactly as
        # {EventStore} hands them back — so the channel above cannot tell which
        # store it is talking to.
        def to_event(row)
          {
            "id" => row["id"].to_i,
            "topic" => row["topic"],
            "subject" => row["subject"],
            "occurred_at" => as_iso8601(row["occurred_at"]),
            "data" => row["data"].is_a?(String) ? JSON.parse(row["data"]) : row["data"],
          }
        end

        # The adapter may hand back a Time or the raw string depending on how
        # the connection is configured; both render to the one form the wire
        # publishes.
        def as_iso8601(value)
          return value.utc.strftime("%Y-%m-%dT%H:%M:%SZ") if value.respond_to?(:utc)

          Time.parse(value.to_s).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        end

        def prune_if_due!
          now = Time.now.to_i
          due = @mutex.synchronize do
            if now - @last_prune_at >= @prune_interval
              @last_prune_at = now
              true
            else
              false
            end
          end
          prune! if due
        end

        def table = %("#{Kiosk.configuration.schema}".events)

        # `lease_connection`, not `connection`, for the reason
        # {PowSpentStores::ActiveRecord} gives: `ActiveRecord::Base.connection`
        # is soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`.
        def connection = ::ActiveRecord::Base.lease_connection
      end
    end
  end
end
