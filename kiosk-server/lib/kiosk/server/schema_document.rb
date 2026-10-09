# frozen_string_literal: true

require "digest"
require "json"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/schema_slots"
require "kiosk/server/version"

module Kiosk
  module Server
    # The public `GET <endpoint>/schema` catalog, `{queries, actions, events}`,
    # derived at boot and served from memory. Its digest is the origin's
    # document version: the ETag and the `?v=` of the discovery links.
    module SchemaDocument
      DIGEST_LENGTH = 32

      MUTEX = Mutex.new

      class << self
        def document(config: Kiosk.configuration)
          derive(config: config).fetch(:document)
        end

        def json(config: Kiosk.configuration)
          derive(config: config).fetch(:json)
        end

        def digest(config: Kiosk.configuration)
          derive(config: config).fetch(:digest)
        end

        def etag(config: Kiosk.configuration)
          %("#{digest(config: config)}")
        end

        def derived?
          !@memo.nil?
        end

        # Called at boot. With a data-derived slot the database may not exist
        # yet (`db:create`), so a failure leaves the memo empty for the first read.
        def derive!(config: Kiosk.configuration)
          MUTEX.synchronize { @memo = build(config) }
          self
        rescue StandardError => error
          raise unless SchemaSlots.dynamic_declarations?

          @memo = nil
          deferred_derivation_warning(error)
          self
        end

        def reset!
          @memo = nil
          self
        end

        private

        def derive(config:)
          key  = cache_key(config)
          memo = @memo
          return memo if memo && memo[:key] == key

          MUTEX.synchronize do
            # Re-read inside the lock: another thread may have built it.
            key  = cache_key(config)
            memo = @memo
            next memo if memo && memo[:key] == key

            @memo = build(config, key: key)
          end
        end

        def build(config, key: nil)
          document = { queries: Queries.catalog, actions: Actions.catalog,
                       events: Events.catalog }.freeze
          inputs   = digest_inputs(config, document)
          digest   = Digest::SHA256.hexdigest(JSON.generate(inputs))[0, DIGEST_LENGTH]

          { key: key || cache_key(config), document: document,
            json: JSON.generate(document).freeze, digest: digest.freeze }.freeze
        end

        # `SchemaSlots.epoch` moves when a data-derived slot refreshes; else it is 0.
        def cache_key(config)
          [config.object_id, Queries.known.sort, Actions.known.sort, Events.known.sort,
           Array(config.capabilities), SchemaSlots.epoch]
        end

        def deferred_derivation_warning(error)
          message =
            "[kiosk-server] the schema catalog could not be derived at boot " \
            "(#{error.class}: #{error.message}). A descriptor slot on this origin is " \
            "data-derived (a proc), and the data was not reachable — normal during " \
            "db:create, db:migrate and assets:precompile. It will be derived on first read."
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.info(message) : warn(message)
        end

        # Every input of `/schema` and `/openapi.json`, and nothing else.
        def digest_inputs(config, document)
          {
            gem_version:      Kiosk::Server::VERSION,
            protocol_version: Kiosk::Protocol::API_VERSION,
            origins:          config.origins,
            mount_path:       config.mount_path.to_s,
            capabilities:     Array(config.capabilities),
            min_client:       config.min_client.to_s,
            owner:            config.owner,
            skill:            [config.skill_url.to_s, config.skill_sha256.to_s],
            document:         document,
          }
        end
      end
    end
  end
end
