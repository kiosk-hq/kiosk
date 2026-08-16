# frozen_string_literal: true

module Kiosk
  module Server
    # Shared-store adapters for the PoW spent-id set (K-738).
    #
    # The DEFAULT spent store is {Kiosk::Server::PowSpentStore} — a Hash + Mutex
    # living in ONE process (`configuration_extension.rb`, `pow_spent_store`).
    # That is sufficient for a single-process operator and nothing else: the
    # protocol states PoW proofs are single-use (protocol.md Section 15.2), and
    # with an in-process set that property holds PER WORKER, so a proof replayed
    # against a second Puma worker is accepted a second time.
    #
    # This module ships the referent implementation of the shared store the spec
    # requires of a multi-process operator:
    #
    #   Kiosk.configure do |c|
    #     c.pow_spent_store = Kiosk::Server::PowSpentStores::ActiveRecord.new
    #   end
    #
    # Naming note: the in-process store keeps its existing top-level constant
    # ({PowSpentStore}) rather than moving to `PowSpentStores::InMemory` —
    # renaming it would break every operator initializer that references it, and
    # that is not what this change is for.
    module PowSpentStores
      # Spent-id store backed by the `<schema>.pow_spent` table
      # ({SchemaDefinitions.pow_spent_sql}), shared by every process pointed at
      # the same database. Raw SQL through the host's
      # `::ActiveRecord::Base.connection` — the same access idiom as
      # {DeviceAuthorizationStores::ActiveRecord}, so no model class is defined
      # and satellite neutrality holds. ActiveRecord is a declared dependency of
      # this gem; nothing here touches it until an operation runs.
      #
      # == Why the table is not in the install generator
      #
      # The ten canonical migrations are what EVERY operator needs. This table
      # is needed only above `WEB_CONCURRENCY=1`, so it ships as SQL plus this
      # adapter and the operator adds the one-line migration when they scale
      # out. See the kiosk-server README, "Multi-process deployments".
      #
      # == Transaction boundary
      #
      # A claim must be durable independently of the request that made it, or a
      # rollback would un-spend a consumed proof. Both shipped gate call sites
      # run OUTSIDE any transaction — `wire_controller.rb` calls `PowGate.gate`
      # before `Executor.call` opens the GUC-scoped transaction
      # (`wire_controller.rb:94` vs `:113`), and `agent_registration.rb` calls
      # `RegistrationPow.gate` at `:44`, before its `conn.transaction` at `:70`.
      # An operator who wraps the whole request in a transaction of their own
      # (a `before_action`-opened one, say) breaks that and must give this store
      # its own connection.
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
        # ONE statement, per the contract {PowSpentStore#claim} documents: the
        # PRIMARY KEY decides the winner, so N processes racing the same proof
        # produce exactly one `true`. The `ON CONFLICT … DO UPDATE … WHERE
        # s.expires_at <= now()` arm makes an already-expired row reclaimable
        # in that same statement — never a read-then-write, which would
        # reintroduce the TOCTOU {PowGate} closes (K-542).
        #
        # @param id  [String, nil]
        # @param exp [Integer] Unix timestamp at or after which the entry is stale
        # @return [Boolean] true if claimed here, false if already claimed
        def claim(id, exp)
          return false if id.nil?

          prune_if_due!
          conn = connection
          rows = conn.execute(<<~SQL).to_a
            INSERT INTO #{table} AS s (id, expires_at)
            VALUES (#{conn.quote(id)}, to_timestamp(#{exp.to_i}))
            ON CONFLICT (id) DO UPDATE
              SET expires_at = EXCLUDED.expires_at
              WHERE s.expires_at <= now()
            RETURNING s.id
          SQL
          !rows.empty?
        end

        # Release a previously-claimed +id+ (compensating op) — the shared
        # counterpart of {PowSpentStore#release}, so a valid-but-insufficient
        # or unauthenticated proof does not block the client's own retry.
        # @param id [String, nil]
        def release(id)
          return if id.nil?

          conn = connection
          conn.execute(%(DELETE FROM #{table} WHERE id = #{conn.quote(id)}))
          nil
        end

        # @param id [String, nil] the challenge id to check
        # @return [Boolean] true iff a LIVE (unexpired) claim exists
        def spent?(id)
          return false if id.nil?

          conn = connection
          row = conn.execute(<<~SQL).first
            SELECT 1 FROM #{table}
            WHERE id = #{conn.quote(id)} AND expires_at > now()
            LIMIT 1
          SQL
          !row.nil?
        end

        # Idempotent set with no claim semantics — the read-side/override
        # counterpart of {PowSpentStore#mark_spent}. The gate itself uses
        # {#claim}.
        # @param id  [String, nil]
        # @param exp [Integer] Unix timestamp at or after which the entry is stale
        def mark_spent(id, exp)
          return if id.nil?

          conn = connection
          conn.execute(<<~SQL)
            INSERT INTO #{table} (id, expires_at)
            VALUES (#{conn.quote(id)}, to_timestamp(#{exp.to_i}))
            ON CONFLICT (id) DO UPDATE SET expires_at = EXCLUDED.expires_at
          SQL
          nil
        end

        # Delete every entry whose expiry has passed. Called opportunistically
        # by {#claim} at most once per +prune_interval+ per process; also safe
        # to schedule as a periodic job instead.
        def prune!
          connection.execute(%(DELETE FROM #{table} WHERE expires_at <= now()))
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

        def connection = ::ActiveRecord::Base.connection
        def table = %("#{Kiosk.configuration.schema}".pow_spent)
      end
    end
  end
end
