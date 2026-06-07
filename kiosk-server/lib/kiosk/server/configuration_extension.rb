# frozen_string_literal: true

module Kiosk
  module Server
    # Adds server-specific fields to {Kiosk::Configuration} via include.
    # Stacks on top of {Kiosk::RLS::ConfigurationExtension} (which adds
    # `app_role`, `system_role`, `schema`) and the base Configuration
    # attributes from kiosk-core (`user_model`, `user_id_type`,
    # `guc_namespace`, `roles`, `issuer`, …).
    #
    # See design spec §3.4 for the well-known shape and §3.6 for the URL
    # surface map.
    module ConfigurationExtension
      # URL prefix at which kiosk-server is mounted under the provider's
      # origin. Default: `/kiosk` (the spec's suggested default mount path).
      # The well-known document advertises `endpoint = origin + mount_path`.
      attr_writer :mount_path
      def mount_path
        @mount_path ||= Kiosk::Protocol::DEFAULT_MOUNT_PATH
      end

      # Capabilities the server advertises in `/.well-known/kiosk.json`.
      # Default reflects an MVP-complete deployment; providers can prune
      # if they ship only a subset.
      attr_writer :capabilities
      def capabilities
        @capabilities ||= %w[sql actions ap2 events].freeze
      end

      # Owner block for the well-known document. Free-form hash; the spec
      # §3.4 example uses `{ name: ..., support: ... }`. Providers should
      # set at minimum a contact email.
      attr_writer :owner
      def owner
        @owner ||= {}
      end

      # Minimum agent-CLI client version this deployment will accept.
      # Default: {Kiosk::Protocol::MIN_CLIENT}. Providers may bump if they
      # rely on a newer wire feature.
      attr_writer :min_client
      def min_client
        @min_client ||= Kiosk::Protocol::MIN_CLIENT
      end
    end
  end
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
