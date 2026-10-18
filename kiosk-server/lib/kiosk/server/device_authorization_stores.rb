# frozen_string_literal: true

require 'time'

module Kiosk
  module Server
    # Storage for {DeviceAuthorization} rows: {ActiveRecord} (the default) or
    # {InMemory} for tests.
    module DeviceAuthorizationStores
      class UniqueConstraintError < StandardError; end

      class NotFoundError < StandardError; end

      # An adapter must make {#claim_consume} one atomic operation (never a read
      # then {#update}), and {#lookup_by_user_code_hash} must answer only pending rows.
      class Base
        def create(_device_authorization) = raise(NotImplementedError)
        def update(_device_authorization) = raise(NotImplementedError)
        def lookup_by_device_code_hash(_hash) = raise(NotImplementedError)
        def lookup_by_user_code_hash(_hash) = raise(NotImplementedError)
        def claim_consume(_device_authorization, now: Time.current) = raise(NotImplementedError)
      end

      class InMemory < Base
        def initialize
          super
          @by_id = {}
          @mutex = Mutex.new
        end

        def create(authorization)
          @mutex.synchronize do
            ensure_unique!(authorization)
            @by_id[authorization.id] = authorization
          end
          authorization
        end

        def update(authorization)
          @mutex.synchronize do
            raise NotFoundError, "device_authorization #{authorization.id} not found" unless @by_id.key?(authorization.id)

            @by_id[authorization.id] = authorization
          end
          authorization
        end

        def lookup_by_device_code_hash(hash)
          @mutex.synchronize do
            @by_id.values.find { |x| x.device_code_hash == hash }
          end
        end

        # nil when the row is no longer approved.
        def claim_consume(authorization, now: Time.current)
          @mutex.synchronize do
            current = @by_id[authorization.id]
            raise NotFoundError, "device_authorization #{authorization.id} not found" if current.nil?
            return nil unless current.approved?

            @by_id[authorization.id] = current.consume(now: now)
          end
        end

        def lookup_by_user_code_hash(hash)
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

        private

        def ensure_unique!(authorization)
          rows = @by_id.values
          raise UniqueConstraintError, 'device_code_hash already exists' if rows.any? { |x| x.device_code_hash == authorization.device_code_hash }
          return unless authorization.pending? && rows.any? { |x| x.pending? && x.user_code_hash == authorization.user_code_hash }

          raise UniqueConstraintError, 'user_code_hash already exists among pending rows'
        end
      end

      class ActiveRecord < Base
        COLUMNS = %w[id device_code_hash user_code_hash public_key_pem kind client_id requested_role
                     status user_id expires_at consumed_at created_at].freeze
        TIME_COLUMNS = %w[expires_at consumed_at created_at].freeze

        def create(authorization)
          binds = COLUMNS.map { |column| bind_value(authorization.public_send(column)) }
          connection.exec_query(insert_sql, 'Kiosk device_authorization insert', binds)
          authorization
        rescue ::ActiveRecord::RecordNotUnique => e
          raise UniqueConstraintError, e.message
        end

        def update(authorization)
          binds = %i[public_key_pem status user_id consumed_at requested_role id].map do |attribute|
            bind_value(authorization.public_send(attribute))
          end
          updated = connection.exec_query(update_sql, 'Kiosk device_authorization update', binds).to_a
          raise NotFoundError, "device_authorization #{authorization.id} not found" if updated.empty?

          authorization
        end

        # nil when the row is no longer approved; the row, not Ruby, decides the race.
        def claim_consume(authorization, now: Time.current)
          sql = <<~SQL.squish
            UPDATE #{table}
            SET status = 'consumed', consumed_at = $1
            WHERE id = $2 AND status = 'approved'
            RETURNING id
          SQL
          updated = connection.exec_query(sql, 'Kiosk device_authorization claim', [now, authorization.id]).to_a
          return nil if updated.empty?

          authorization.consume(now: now)
        end

        def lookup_by_device_code_hash(hash)
          sql = <<~SQL.squish
            SELECT * FROM #{table}
            WHERE device_code_hash = $1
            LIMIT 1
          SQL
          row = connection.exec_query(sql, 'Kiosk device_authorization by device code', [hash]).to_a.first
          row && row_to_authorization(row)
        end

        def lookup_by_user_code_hash(hash)
          sql = <<~SQL.squish
            SELECT * FROM #{table}
            WHERE user_code_hash = $1 AND status = 'pending'
            LIMIT 1
          SQL
          row = connection.exec_query(sql, 'Kiosk device_authorization by user code', [hash]).to_a.first
          row && row_to_authorization(row)
        end

        private

        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".device_authorizations)

        def insert_sql
          placeholders = (1..COLUMNS.size).map { |i| "$#{i}" }.join(', ')
          "INSERT INTO #{table} (#{COLUMNS.join(', ')}) VALUES (#{placeholders})"
        end

        def update_sql
          <<~SQL.squish
            UPDATE #{table}
            SET public_key_pem = $1, status = $2, user_id = $3, consumed_at = $4, requested_role = $5
            WHERE id = $6
            RETURNING id
          SQL
        end

        def bind_value(value) = value.is_a?(Symbol) ? value.to_s : value

        def row_to_authorization(row)
          attributes = COLUMNS.to_h do |column|
            value = row.fetch(column)
            [column.to_sym, TIME_COLUMNS.include?(column) ? to_time(value) : value]
          end
          DeviceAuthorization.new(**attributes)
        end

        def to_time(value)
          return value if value.nil? || value.is_a?(Time)

          Time.parse(value.to_s).utc
        end
      end
    end
  end
end
