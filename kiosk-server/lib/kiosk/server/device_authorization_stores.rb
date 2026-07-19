# frozen_string_literal: true

require "time"

module Kiosk
  module Server
    # Persistence layer for {DeviceAuthorization} rows. Adapter pattern —
    # {Base} defines the contract; two adapters ship:
    #
    #   - {ActiveRecord} — durable store over the `kiosk.device_authorizations`
    #     table (schema_definitions migration 008). The DEFAULT whenever
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

      # Abstract contract. Adapters implement four operations.
      class Base
        def create(_device_authorization);        raise NotImplementedError; end
        def update(_device_authorization);        raise NotImplementedError; end
        def find_by_device_code_hash(_hash);      raise NotImplementedError; end
        def find_by_user_code_hash(_hash);        raise NotImplementedError; end
      end

      # In-process store. Backed by a Hash keyed by id; lookups iterate.
      # Thread-safe via a Mutex (binding ceremonies are low-frequency by
      # nature — one row per request, then consumed). Suitable for
      # development, unit tests, and single-process deployments; a
      # multi-process deployment uses the {ActiveRecord} adapter (the
      # default when ActiveRecord is present).
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
      # (schema_definitions migration 008). Raw SQL through the host's
      # `::ActiveRecord::Base.connection` — the same access idiom as
      # {AgentRegistration} / {AgentLogin}; no model class, so satellite
      # neutrality holds (Kiosk never defines records over provider
      # tables, and this one lives in the kiosk schema).
      #
      # Requires ActiveRecord in the host process; the class itself is
      # defined unconditionally (nothing references ActiveRecord until an
      # operation runs), matching the conditional-use pattern of the rest
      # of the gem.
      class ActiveRecord < Base
        def create(da)
          conn = connection
          conn.execute(<<~SQL)
            INSERT INTO #{table} (id, device_code_hash, user_code_hash, public_key_pem, kind,
                                  client_id, requested_role, status, user_id,
                                  expires_at, consumed_at, created_at)
            VALUES (#{conn.quote(da.id)}, #{conn.quote(da.device_code_hash)},
                    #{conn.quote(da.user_code_hash)}, #{conn.quote(da.public_key_pem)},
                    #{conn.quote(da.kind.to_s)}, #{conn.quote(da.client_id)},
                    #{conn.quote(da.requested_role)}, #{conn.quote(da.status.to_s)},
                    #{conn.quote(da.user_id)}, #{conn.quote(da.expires_at)},
                    #{conn.quote(da.consumed_at)}, #{conn.quote(da.created_at)})
          SQL
          da
        rescue ::ActiveRecord::RecordNotUnique => e
          raise UniqueConstraintError, e.message
        end

        def update(da)
          conn = connection
          updated = conn.execute(<<~SQL).to_a
            UPDATE #{table}
            SET public_key_pem = #{conn.quote(da.public_key_pem)},
                status         = #{conn.quote(da.status.to_s)},
                user_id        = #{conn.quote(da.user_id)},
                consumed_at    = #{conn.quote(da.consumed_at)}
            WHERE id = #{conn.quote(da.id)}
            RETURNING id
          SQL
          if updated.empty?
            raise NotFoundError, "device_authorization #{da.id} not found"
          end

          da
        end

        def find_by_device_code_hash(hash)
          conn = connection
          row = conn.execute(<<~SQL).first
            SELECT * FROM #{table}
            WHERE device_code_hash = #{conn.quote(hash)}
            LIMIT 1
          SQL
          row && row_to_authorization(row)
        end

        # Pending-only, mirroring {InMemory#find_by_user_code_hash}: the
        # partial unique index guarantees at most one pending row per code.
        def find_by_user_code_hash(hash)
          conn = connection
          row = conn.execute(<<~SQL).first
            SELECT * FROM #{table}
            WHERE user_code_hash = #{conn.quote(hash)} AND status = 'pending'
            LIMIT 1
          SQL
          row && row_to_authorization(row)
        end

        private

        def connection = ::ActiveRecord::Base.connection
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
