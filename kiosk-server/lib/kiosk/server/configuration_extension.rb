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

      # RSA signing key used by the OAuth 2.1 surface (§6.7) and the
      # bundled IdP (§6.2) to issue JWTs.
      #
      # Resolution order:
      #   1. explicit value set via `Kiosk.configure { |c| c.signing_key = ... }`
      #      (accepts a {Kiosk::Server::SigningKey} or a PEM string)
      #   2. PEM from the `KIOSK_SIGNING_KEY_PEM` env var (production path)
      #   3. fresh in-memory RSA 2048 keypair (dev path — every process
      #      restart issues new tokens, which is fine for local development
      #      but never for production)
      #
      # @return [Kiosk::Server::SigningKey]
      def signing_key
        @signing_key ||= default_signing_key
      end

      def signing_key=(value)
        @signing_key = case value
                       when Kiosk::Server::SigningKey
                         value
                       when String
                         Kiosk::Server::SigningKey.from_pem(value)
                       when nil
                         nil
                       else
                         raise ArgumentError,
                           "signing_key must be a SigningKey or PEM string, got #{value.class}"
                       end
      end

      # Minimum leading zero BITS required in the PoW digest at agent
      # registration (`SHA256(public_key_pem + "." + pow_nonce)`).
      # Default 0 = disabled (open registration — Plan 2/3 behaviour unchanged).
      # Providers that gate physical-service access can set e.g. 20.
      attr_writer :registration_difficulty
      def registration_difficulty
        @registration_difficulty ||= 0
      end

      # Issuer string of the trusted KYC attestation provider.
      # Must match the `iss` claim of submitted KYC JWS tokens.
      attr_writer :kyc_issuer
      def kyc_issuer
        @kyc_issuer
      end

      # RSA public key ({OpenSSL::PKey::RSA} or PEM string) of the trusted
      # KYC provider. Used by {KycVerifier} to verify attestation JWS tokens.
      def kyc_public_key
        @kyc_public_key
      end

      def kyc_public_key=(value)
        @kyc_public_key = case value
                          when OpenSSL::PKey::PKey then value
                          when String              then OpenSSL::PKey::RSA.new(value)
                          when nil                 then nil
                          else
                            raise ArgumentError,
                              "kyc_public_key must be an OpenSSL::PKey or PEM string, got #{value.class}"
                          end
      end

      # Ed25519 private key ({OpenSSL::PKey::PKey}) used by {RentalTokenIssuer}
      # to sign offline rental tokens. The public half is baked into every
      # scooter lock at provisioning time.
      #
      # Provide as an OpenSSL::PKey::PKey (Ed25519) instance.
      # In production load from an env var / secrets manager; in the demo
      # a fixed dev keypair (DevUnlockKey) is used so vectors are stable.
      attr_accessor :unlock_signing_key

      # Storage adapter for {Kiosk::Server::DeviceAuthorization} rows
      # (§6.5 + §6.7 Device-Grant state machine). Lazy-defaults to
      # {DeviceAuthorizationStores::InMemory} — fine for development +
      # tests + small single-process deployments. Production Rails apps
      # set this to the ActiveRecord-backed adapter (lands in a
      # follow-up release).
      #
      # @return [DeviceAuthorizationStores::Base]
      attr_writer :device_authorization_store
      def device_authorization_store
        @device_authorization_store ||= Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      end

      private

      def default_signing_key
        pem = ENV["KIOSK_SIGNING_KEY_PEM"]
        return Kiosk::Server::SigningKey.from_pem(pem) if pem && !pem.empty?

        Kiosk::Server::SigningKey.generate
      end
    end
  end
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
