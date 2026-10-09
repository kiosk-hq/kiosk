# frozen_string_literal: true

module Kiosk
  module Server
    module EventStores
      # The deployed event store: the `<schema>.events` table, shared by every process on the database.
      #   c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
      class ActiveRecord
        # The published retention floor: at least this much history per identity.
        DEFAULT_RETENTION_HOURS = 24

        # Seconds between opportunistic retention sweeps.
        DEFAULT_PRUNE_INTERVAL = 300

        # Retention is by time only; a row-count ceiling would become the real
        # retention on a busy subject.
        def initialize(retention_hours: DEFAULT_RETENTION_HOURS,
                       prune_interval: DEFAULT_PRUNE_INTERVAL)
          @retention_hours = retention_hours
          @prune_interval  = prune_interval
          @last_prune_at   = 0
          @mutex           = Mutex.new
        end

        # `event` is string-keyed, without "id"; returns the id the sequence assigned.
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

        # This identity's events after the cursor `id`, ascending.
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

        # The origin's maximum id, 0 when empty.
        def head
          row = connection.exec_query(
            %(SELECT COALESCE(MAX(id), 0) AS head FROM #{table}), "Kiosk events head"
          ).to_a.first
          row["head"].to_i
        end

        # True when rows after the caller's cursor were swept; a cursor at or
        # past the newest row missed nothing.
        def truncated?(_identity_key, id)
          row = connection.exec_query(
            %(SELECT COALESCE(MIN(id), 0) AS floor, COALESCE(MAX(id), 0) AS head FROM #{table}),
            "Kiosk events floor",
          ).to_a.first
          return false if row["head"].to_i <= id.to_i

          row["floor"].to_i > id.to_i + 1
        end

        # Deletes everything older than the retention window; {#append} calls
        # it at most once per +prune_interval+ per process.
        def prune!
          connection.exec_query(
            %(DELETE FROM #{table} WHERE created_at < now() - ($1 || ' hours')::interval),
            "Kiosk events prune", [@retention_hours.to_s],
          )
          nil
        end

        private

        # The wire's five event members, string-keyed, as {EventStore} gives them.
        def to_event(row)
          {
            "id" => row["id"].to_i,
            "topic" => row["topic"],
            "subject" => row["subject"],
            "occurred_at" => as_iso8601(row["occurred_at"]),
            "data" => row["data"].is_a?(String) ? JSON.parse(row["data"]) : row["data"],
          }
        end

        # The adapter may return a Time or a String.
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

        # `connection` raises under `permanent_connection_checkout = :disallowed`.
        def connection = ::ActiveRecord::Base.lease_connection
      end
    end
  end
end
