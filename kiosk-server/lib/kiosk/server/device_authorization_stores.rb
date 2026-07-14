# frozen_string_literal: true

module Kiosk
  module Server
    # Persistence layer for {DeviceAuthorization} rows. Adapter pattern —
    # {Base} defines the contract; only the in-memory {InMemory} store ships
    # in 0.1. A durable (e.g. ActiveRecord-backed) adapter is NOT included;
    # a host that needs one implements the four {Base} operations itself.
    #
    # Resolved via {Kiosk::Configuration#device_authorization_store}
    # with lazy default {InMemory}.
    module DeviceAuthorizationStores
      # Raised when a write would violate device_code_hash uniqueness
      # or the pending-user_code uniqueness window. A durable adapter is
      # expected to translate the underlying PG ‹unique_violation› into this
      # same class so callers can `rescue` uniformly.
      class UniqueConstraintError < StandardError; end

      # Raised by {Base#update} when no row matches the supplied id.
      class NotFoundError < StandardError; end

      # Abstract contract. Adapters implement four operations.
      class Base
        def create(_device_authorization);      raise NotImplementedError; end
        def update(_device_authorization);      raise NotImplementedError; end
        def find_by_device_code_hash(_hash);    raise NotImplementedError; end
        def find_by_user_code(_user_code);      raise NotImplementedError; end
      end

      # In-process store. Backed by a Hash keyed by id; lookups iterate.
      # Thread-safe via a Mutex (Device-Grant flows are low-frequency by
      # nature — one row per device-authorization request, then consumed).
      # This is the only store that ships in 0.1: suitable for development,
      # integration tests, and small single-process deployments. A
      # multi-process deployment needs a durable {Base} implementation.
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
               @by_id.values.any? { |x| x.pending? && x.user_code == da.user_code }
              raise UniqueConstraintError, "user_code already exists among pending rows"
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
        def find_by_user_code(user_code)
          @mutex.synchronize do
            @by_id.values.find { |x| x.user_code == user_code && x.pending? }
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
    end
  end
end
