# frozen_string_literal: true

require "time"

module Kiosk
  module Server
    # Storage for {DeviceAuthorization} rows: {ActiveRecord} (the default) or
    # {InMemory} for tests.
    module DeviceAuthorizationStores
      class UniqueConstraintError < StandardError; end

      class NotFoundError < StandardError; end

      # An adapter must make {#claim_consume} one atomic operation (never a read
      # then {#update}), and {#find_by_user_code_hash} must answer only pending rows.
      class Base
        def create(_device_authorization);        raise NotImplementedError; end
        def update(_device_authorization);        raise NotImplementedError; end
        def find_by_device_code_hash(_hash);      raise NotImplementedError; end
        def find_by_user_code_hash(_hash);        raise NotImplementedError; end
        def claim_consume(_device_authorization, now: Time.now); raise NotImplementedError; end
      end

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

        # nil when the row is no longer approved.
        def claim_consume(da, now: Time.now)
          @mutex.synchronize do
            current = @by_id[da.id]
            raise NotFoundError, "device_authorization #{da.id} not found" if current.nil?
            return nil unless current.approved?

            @by_id[da.id] = current.consume(now: now)
          end
        end

        def find_by_user_code_hash(hash)
          @mutex.synchronize do
            @by_id.values.find { |x| x.user_code_hash == hash && x.pending? }
          end
        end

        def reset!
          @mutex.synchronize { @by_id.clear }
        end

        def size
          @mutex.synchronize { @by_id.size }
        end
      end

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

        # nil when the row is no longer approved; the row, not Ruby, decides the race.
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

        def to_time(value)
          return value if value.nil? || value.is_a?(Time)

          Time.parse(value.to_s)
        end
      end
    end
  end
end
