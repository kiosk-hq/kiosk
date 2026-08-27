# frozen_string_literal: true

require "time"

module Kiosk
  module Server
    # Persistence layer for {DeviceAuthorization} rows. Adapter pattern —
    # {Base} defines the contract; two adapters ship:
    #
    #   - {ActiveRecord} — durable store over the `kiosk.device_authorizations`
    #     table (schema_definitions migration 004). The DEFAULT whenever
    #     ActiveRecord is present (the binding ceremony is
    #     cross-process by nature — the human approves in a browser while the
    #     agent polls from another process; an in-memory row can't serve both).
    #   - {InMemory} — in-process store for tests and single-process
    #     development.
    #
    # Resolved via {Kiosk::Configuration#device_authorization_store}.
    module DeviceAuthorizationStores
      # Raised when a write would violate device_code_hash uniqueness
      # or the pending-user_code uniqueness window. The durable adapter
      # translates the underlying PG ‹unique_violation› into this same
      # class so callers can `rescue` uniformly.
      class UniqueConstraintError < StandardError; end

      # Raised by {Base#update} when no row matches the supplied id.
      class NotFoundError < StandardError; end

      # Abstract contract. Adapters implement five operations.
      #
      # {#claim_consume} is the single-use gate and it is deliberately NOT
      # expressible as `find` + `update`: single-use has to be decided BY THE
      # ROW, in one operation, or two concurrent redemptions of the same code
      # both pass a check made against a snapshot and both bind (K-887). The
      # sibling controls in this gem take the same shape and say so in the same
      # words -- {PowSpentStore#claim} ("NOT a read-then-write, which
      # reintroduces the very TOCTOU this method closes") and
      # {AuthChallengeStores::ActiveRecord#take} (one `DELETE ... RETURNING`).
      # An override that implements it as a read followed by {#update} is a
      # defect, not a style choice.
      class Base
        def create(_device_authorization);        raise NotImplementedError; end
        def update(_device_authorization);        raise NotImplementedError; end
        def find_by_device_code_hash(_hash);      raise NotImplementedError; end
        def find_by_user_code_hash(_hash);        raise NotImplementedError; end
        def claim_consume(_device_authorization, now: Time.now); raise NotImplementedError; end
      end

      # In-process store. Backed by a Hash keyed by id; lookups iterate.
      # Thread-safe via a Mutex (binding ceremonies are low-frequency by
      # nature — one row per request, then consumed). Suitable for
      # development, unit tests, and single-process deployments; a
      # multi-process deployment uses the {ActiveRecord} adapter (the
      # default).
      class InMemory < Base
        def initialize
          @by_id = {}
          @mutex = Mutex.new
        end

        def create(da)
          @mutex.synchronize do
            if @by_id.values.any? { |x| x.device_code_hash == da.device_code_hash }
              raise UniqueConstraintError, "device_code_hash already exists"
            end
            if da.pending? &&
               @by_id.values.any? { |x| x.pending? && x.user_code_hash == da.user_code_hash }
              raise UniqueConstraintError, "user_code_hash already exists among pending rows"
            end
            @by_id[da.id] = da
          end
          da
        end

        def update(da)
          @mutex.synchronize do
            unless @by_id.key?(da.id)
              raise NotFoundError, "device_authorization #{da.id} not found"
            end
            @by_id[da.id] = da
          end
          da
        end

        def find_by_device_code_hash(hash)
          @mutex.synchronize do
            @by_id.values.find { |x| x.device_code_hash == hash }
          end
        end

        # Atomic single-use claim (K-887). The status is re-read INSIDE the
        # mutex, so a caller holding a stale `:approved` snapshot loses the
        # race rather than overwriting the winner's consume.
        # @return [DeviceAuthorization, nil] the consumed row, or nil when it
        #   was no longer `:approved` (already consumed / denied / expired)
        def claim_consume(da, now: Time.now)
          @mutex.synchronize do
            current = @by_id[da.id]
            raise NotFoundError, "device_authorization #{da.id} not found" if current.nil?
            return nil unless current.approved?

            @by_id[da.id] = current.consume(now: now)
          end
        end

        # Per spec, user_code only resolves while the row is still pending
        # (so the user can approve / deny). Already-approved/consumed rows
        # are invisible to /oauth/device/verify by design.
        def find_by_user_code_hash(hash)
          @mutex.synchronize do
            @by_id.values.find { |x| x.user_code_hash == hash && x.pending? }
          end
        end

        # Test/dev helper. Not part of {Base} contract.
        def reset!
          @mutex.synchronize { @by_id.clear }
        end

        # Test/dev helper. Returns count of rows; useful for assertions
        # like "expected one device_authorization to land".
        def size
          @mutex.synchronize { @by_id.size }
        end
      end

      # Durable store over the `kiosk.device_authorizations` table
      # (schema_definitions migration 004). SQL with BIND PARAMETERS through
      # the host's `::ActiveRecord::Base.lease_connection` — the same access
      # idiom as {AgentRegistration} / {AgentLogin}; no model class, so
      # satellite neutrality holds (Kiosk never defines records over provider
      # tables, and this one lives in the kiosk schema).
      #
      # Every value here reaches the row from a request: the public key and
      # `client_id` are the caller's own fields, the code hashes are digests of
      # codes the caller presents. None of them is ever concatenated into a
      # statement — see {#connection} for why the acquisition changed too.
      #
      # ActiveRecord is a declared dependency of the gem; nothing here
      # touches it until an operation runs.
      class ActiveRecord < Base
        def create(da)
          sql = <<~SQL
            INSERT INTO #{table} (id, device_code_hash, user_code_hash, public_key_pem, kind,
                                  client_id, requested_role, status, user_id,
                                  expires_at, consumed_at, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
          connection.exec_query(sql, "Kiosk device_authorization insert", [
            da.id, da.device_code_hash, da.user_code_hash, da.public_key_pem,
            da.kind.to_s, da.client_id, da.requested_role, da.status.to_s,
            da.user_id, da.expires_at, da.consumed_at, da.created_at,
          ])
          da
        rescue ::ActiveRecord::RecordNotUnique => e
          raise UniqueConstraintError, e.message
        end

        # `requested_role` IS IN THE SET LIST, and it has to be (K-072). It
        # used to be absent because the column was written once, at INSERT: a
        # claim row carried whatever role the opening request asked for, and a
        # link row carried the minting human's, so nothing ever changed it
        # afterwards. Since the claim ceremony's role is captured at APPROVAL
        # instead — from the approving human's `Identity#role` — `approve` is
        # exactly a mid-life write to this column, and a store that dropped it
        # would persist the approval while silently discarding the role, so
        # every claim-bound assistant on a durable store would fall back to
        # `registration_role`. The in-memory adapter replaces the whole value
        # object and never had the gap, which is precisely why this is the
        # adapter where such a bug hides from a unit suite.
        def update(da)
          sql = <<~SQL
            UPDATE #{table}
            SET public_key_pem = $1,
                status         = $2,
                user_id        = $3,
                consumed_at    = $4,
                requested_role = $5
            WHERE id = $6
            RETURNING id
          SQL
          updated = connection.exec_query(sql, "Kiosk device_authorization update", [
            da.public_key_pem, da.status.to_s, da.user_id, da.consumed_at,
            da.requested_role, da.id,
          ]).to_a
          if updated.empty?
            raise NotFoundError, "device_authorization #{da.id} not found"
          end

          da
        end

        # Atomic single-use claim (K-887). ONE conditional statement: the
        # `AND status = 'approved'` predicate is what makes the row -- not a
        # Ruby check against a snapshot -- decide the winner, so two concurrent
        # redemptions of one link code produce one bind and one `409`.
        # `'approved'` / `'consumed'` stay literals: they are state names
        # written in this file, not values anyone supplies.
        # @return [DeviceAuthorization, nil] the consumed row, or nil when the
        #   row was no longer `approved` (lost the race, or never eligible)
        def claim_consume(da, now: Time.now)
          sql = <<~SQL
            UPDATE #{table}
            SET status = 'consumed', consumed_at = $1
            WHERE id = $2 AND status = 'approved'
            RETURNING id
          SQL
          updated = connection.exec_query(sql, "Kiosk device_authorization claim", [now, da.id]).to_a
          return nil if updated.empty?

          da.consume(now: now)
        end

        def find_by_device_code_hash(hash)
          sql = <<~SQL
            SELECT * FROM #{table}
            WHERE device_code_hash = $1
            LIMIT 1
          SQL
          row = connection.exec_query(sql, "Kiosk device_authorization by device code", [hash]).to_a.first
          row && row_to_authorization(row)
        end

        # Pending-only, mirroring {InMemory#find_by_user_code_hash}: the
        # partial unique index guarantees at most one pending row per code.
        # `'pending'` stays a literal — it is a state name written in this file,
        # not a value anyone supplies.
        def find_by_user_code_hash(hash)
          sql = <<~SQL
            SELECT * FROM #{table}
            WHERE user_code_hash = $1 AND status = 'pending'
            LIMIT 1
          SQL
          row = connection.exec_query(sql, "Kiosk device_authorization by user code", [hash]).to_a.first
          row && row_to_authorization(row)
        end

        private

        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`, which would 500 the
        # whole binding ceremony on a host that took the new default. Each
        # method here is one statement in no transaction of its own, so
        # `with_connection` would also be correct; the lease is taken because
        # every call site is inside a Rails request that already holds one, and
        # because two connection idioms in one engine is what K-782 closes.
        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".device_authorizations)

        def row_to_authorization(row)
          DeviceAuthorization.new(
            id:               row.fetch("id"),
            device_code_hash: row.fetch("device_code_hash"),
            user_code_hash:   row.fetch("user_code_hash"),
            public_key_pem:   row.fetch("public_key_pem"),
            kind:             row.fetch("kind").to_sym,
            client_id:        row.fetch("client_id"),
            requested_role:   row.fetch("requested_role"),
            status:           row.fetch("status").to_sym,
            user_id:          row.fetch("user_id"),
            expires_at:       to_time(row.fetch("expires_at")),
            consumed_at:      to_time(row.fetch("consumed_at")),
            created_at:       to_time(row.fetch("created_at")),
          )
        end

        # `connection.execute` yields timestamptz values as Time or String
        # depending on the adapter's registered decoders; normalise to Time.
        def to_time(value)
          return value if value.nil? || value.is_a?(Time)

          Time.parse(value.to_s)
        end
      end
    end
  end
end
