# frozen_string_literal: true

module Kiosk
  module Server
    # Stores for the PoW spent-id set (`config.pow_spent_store`). A store
    # answers `claim(id, exp)` (atomic: true iff this caller claimed it),
    # `release(id)`, `spent?(id)` and `mark_spent(id, exp)`.
    module PowSpentStores
      # The default store: the `<schema>.pow_spent` table
      # ({SchemaDefinitions.pow_spent_sql}, laid down by `kiosk:install`), so a
      # spent proof stays spent across workers, hosts and deploys. Plain SQL
      # with bind parameters through `::ActiveRecord::Base.lease_connection`;
      # no model class.
      #
      # Every gate call site runs outside a transaction, so a claim is durable
      # independently of the request that made it.
      class ActiveRecord
        # Seconds between opportunistic TTL sweeps. The sweep exists to bound
        # table growth, NOT for correctness (challenge ids are random, so an
        # expired row is never re-claimed by a different challenge), so it is
        # throttled hard rather than run on every claim.
        DEFAULT_PRUNE_INTERVAL = 60

        # @param prune_interval [Integer] seconds; 0 sweeps on every claim
        def initialize(prune_interval: DEFAULT_PRUNE_INTERVAL)
          @prune_interval = prune_interval
          @last_prune_at  = 0
          @mutex          = Mutex.new
        end

        # Atomically claim +id+ as spent until Unix timestamp +exp+.
        #
        # One statement: the PRIMARY KEY decides the winner, so N processes
        # racing the same proof produce exactly one `true`; an expired row is
        # reclaimable in that same statement.
        #
        # @param id  [String, nil]
        # @param exp [Integer] Unix timestamp at or after which the entry is stale
        # @return [Boolean] true if claimed here, false if already claimed
        def claim(id, exp)
          return false if id.nil?

          prune_if_due!
          # The challenge id is CALLER-SUPPLIED — it is the `jti`-shaped id off
          # the presented proof — so it is `$1`. `exp` is derived server-side
          # but is still a value, so it is `$2` inside `to_timestamp`.
          sql = <<~SQL
            INSERT INTO #{table} AS s (id, expires_at)
            VALUES ($1, to_timestamp($2))
            ON CONFLICT (id) DO UPDATE
              SET expires_at = EXCLUDED.expires_at
              WHERE s.expires_at <= now()
            RETURNING s.id
          SQL
          rows = connection.exec_query(sql, "Kiosk pow_spent claim", [id, exp.to_i]).to_a
          !rows.empty?
        end

        # Release a previously-claimed +id+, so a valid-but-insufficient or
        # unauthenticated proof does not block the client's own retry.
        # @param id [String, nil]
        def release(id)
          return if id.nil?

          connection.exec_query(%(DELETE FROM #{table} WHERE id = $1), "Kiosk pow_spent release", [id])
          nil
        end

        # @param id [String, nil] the challenge id to check
        # @return [Boolean] true iff a LIVE (unexpired) claim exists
        def spent?(id)
          return false if id.nil?

          sql = <<~SQL
            SELECT 1 FROM #{table}
            WHERE id = $1 AND expires_at > now()
            LIMIT 1
          SQL
          row = connection.exec_query(sql, "Kiosk pow_spent lookup", [id]).to_a.first
          !row.nil?
        end

        # Idempotent set with no claim semantics. The gate itself uses {#claim}.
        # @param id  [String, nil]
        # @param exp [Integer] Unix timestamp at or after which the entry is stale
        def mark_spent(id, exp)
          return if id.nil?

          sql = <<~SQL
            INSERT INTO #{table} (id, expires_at)
            VALUES ($1, to_timestamp($2))
            ON CONFLICT (id) DO UPDATE SET expires_at = EXCLUDED.expires_at
          SQL
          connection.exec_query(sql, "Kiosk pow_spent mark", [id, exp.to_i])
          nil
        end

        # Delete every entry whose expiry has passed. Called opportunistically
        # by {#claim} at most once per +prune_interval+ per process; also safe
        # to schedule as a periodic job instead.
        def prune!
          # No values at all — `now()` is the server's, so this one carries no
          # binds and never did.
          connection.exec_query(%(DELETE FROM #{table} WHERE expires_at <= now()), "Kiosk pow_spent prune")
          nil
        end

        private

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

        # `lease_connection`: `connection` raises under
        # `permanent_connection_checkout = :disallowed`.
        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".pow_spent)
      end
    end
  end
end
