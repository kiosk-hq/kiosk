# frozen_string_literal: true

module Kiosk
  module Server
    # Adds server-specific fields to {Kiosk::Configuration} via include.
    # Stacks on top of the base Configuration attributes from kiosk-core
    # (`user_model`, `user_id_type`, `guc_namespace`, `schema`, `app_role`,
    # `roles`, `issuer`, …).
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

      # When true, SessionContext appends `SET LOCAL ROLE <app_role>` inside
      # EVERY request transaction (query / run / pay verbs) — the DB-privilege
      # backstop for opt-in RLS enforcement. app_role must then hold complete
      # GRANTs on every table those verbs touch: the kiosk.* mandate tables
      # (kiosk.agents, kiosk.intent_mandates, kiosk.cart_mandates,
      # kiosk.payment_mandates, kiosk.settlements, …) and all application
      # tables reached by registered queries and actions. Default false.
      attr_writer :enforce_db_role
      def enforce_db_role
        @enforce_db_role ||= false
      end

      # Capabilities the server advertises in `/.well-known/kiosk.json`.
      # Default reflects an MVP-complete deployment; providers can prune
      # if they ship only a subset.
      attr_writer :capabilities
      def capabilities
        @capabilities ||= %w[query actions ap2].freeze
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

      # Skill descriptor advertised in `/.well-known/kiosk.json` (the
      # "Dual-check" contract in skill.md): the canonical, versioned skill
      # URL plus the SHA-256 of its content, so an agent can verify the
      # skill it cached (or is about to fetch) is the one this provider
      # was built against.
      #
      # The `skill` block is emitted only when `skill_sha256` is set — a
      # stale hash baked into the gem would be worse than no block at all.
      # Providers set it in the initializer and update it when they adopt
      # a newer skill version.
      attr_writer :skill_url
      def skill_url
        @skill_url ||= "https://kiosk.tech/skill-v1.0.md"
      end
      attr_accessor :skill_sha256

      # RSA signing key used by the OAuth 2.1 surface (§6.7) and the
      # bundled IdP (§6.2) to issue JWTs.
      #
      # Resolution order:
      #   1. explicit value set via `Kiosk.configure { |c| c.signing_key = ... }`
      #      (accepts a {Kiosk::Server::SigningKey} or a PEM string)
      #   2. PEM from the `KIOSK_SIGNING_KEY_PEM` env var, or base64-encoded
      #      PEM from `KIOSK_SIGNING_KEY_B64` (single-line friendly for
      #      mise.toml / dotenv)
      #   3. otherwise RAISES with generation instructions. Auto-generation
      #      was removed on purpose: a fresh per-boot key silently
      #      invalidates every issued JWT — agents are forced to re-register
      #      and lose their Stripe Customer card associations.
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

      # Number of independent Equihash proofs required at agent registration
      # (`POST /auth/register`). Default 0 = disabled (open registration).
      # Providers that gate physical-service access, or want to price fresh
      # identity minting, set e.g. 1. When > 0, registration uses the SAME
      # Equihash challenge-response as the reputation gate (see {RegistrationPow}),
      # so `pow_secret` must also be set and `kiosk-pow-equihash` loaded.
      attr_writer :registration_pow_count
      def registration_pow_count
        @registration_pow_count ||= 0
      end

      # Equihash params for the registration gate. Default nil → the shipped
      # `kiosk-pow-equihash` defaults (`Kiosk::Pow::Equihash.params`). Override
      # to demand different (n, k).
      attr_accessor :registration_pow_params

      # Removed 2026-07-08 (ADR-0001 amended: "one PoW = Equihash"). The old
      # SHA256 leading-zero-bits registration hashcash is gone — SHA256 is the
      # most ASIC-optimised hash on Earth, exactly the CPU-hard PoW the ADR
      # drops. Use `registration_pow_count` (Equihash) instead.
      def registration_difficulty=(_)
        raise ArgumentError,
          "registration_difficulty (SHA256 hashcash) was removed — ADR-0001 amended, " \
          "one PoW = Equihash. Use `c.registration_pow_count = 1` (Equihash) and set " \
          "`c.pow_secret`."
      end

      # Role assigned to every self-registered agent. Self-registration mints a
      # Bearer token with no human in the loop, so the role is pinned by the
      # provider server-side — an agent CANNOT choose its own role (that would
      # be a privilege-selection primitive: the role lands in a `SET LOCAL` GUC
      # every RLS policy trusts). Privileged roles are obtainable only through
      # the human-approved device-grant flow.
      #
      # No default: self-registration raises a ConfigurationError until the
      # provider sets this explicitly. Must be one of {#roles}.
      #   Kiosk.configure { |c| c.registration_role = :customer }
      attr_accessor :registration_role

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

      # ── PoW challenge-response gate (R2) ──────────────────────────────────

      # Reputation policy that decides when and how hard to challenge a request.
      # Default nil = never challenge (zero overhead; existing behaviour unchanged).
      # Set to a `Kiosk::Reputation::Policy` instance (or any object responding to
      # `#challenge_for(identity:, verb:, factors:) → {alg:,params:}|nil`).
      attr_writer :reputation_policy
      def reputation_policy
        @reputation_policy
      end

      # HMAC key used to sign/verify challenges. Required when reputation_policy
      # is set; a ConfigurationError is raised at gate-call time if it is nil.
      # In production read from an env var / secrets manager:
      #   c.pow_secret = ENV.fetch("KIOSK_POW_SECRET")
      attr_accessor :pow_secret

      # Challenge TTL in seconds. Default 300 (5 minutes).
      attr_writer :pow_ttl
      def pow_ttl
        @pow_ttl ||= 300
      end

      # Callable `(identity:, verb:) → Kiosk::Reputation::Factors` that the
      # host supplies to let the policy see reputation context. Default returns
      # `Factors.empty` (all fields nil) — safe when kiosk-reputation IS loaded
      # (which it must be when a policy is set). The body is a lambda, so
      # `Kiosk::Reputation::Factors` is NOT referenced at definition time;
      # nil-policy apps without kiosk-reputation still boot.
      attr_writer :reputation_factors
      def reputation_factors
        @reputation_factors ||= ->(**) { ::Kiosk::Reputation::Factors.empty }
      end

      # Callable `(identity:) → void` invoked when a submitted proof is
      # cryptographically invalid (wrong nonce). The host increments the
      # principal's `bad_proof_count` here. Default: no-op.
      attr_writer :on_bad_proof
      def on_bad_proof
        @on_bad_proof ||= ->(**) {}
      end

      # In-process TTL store for spent challenge ids. Override with a
      # shared-store implementation (e.g. Redis-backed) in multi-process
      # deployments to prevent replay attacks across processes.
      #
      # @return [Kiosk::Server::PowSpentStore, #spent?(id), #mark_spent(id, exp)]
      attr_writer :pow_spent_store
      def pow_spent_store
        @pow_spent_store ||= Kiosk::Server::PowSpentStore.new
      end

      # ── PoP auth handshake (challenge-response) ───────────────────────────

      # In-process store binding a public key to its outstanding, single-use
      # auth challenge nonce (the server side of `/auth/challenge`). Override
      # with a shared-store implementation in multi-process deployments.
      #
      # @return [Kiosk::Server::AuthChallengeStore, #put, #take]
      attr_writer :auth_challenge_store
      def auth_challenge_store
        @auth_challenge_store ||= Kiosk::Server::AuthChallengeStore.new
      end

      # Auth-challenge lifetime in seconds — the window an agent has between
      # `GET /auth/challenge` and its signed `POST /auth/{register,login}`.
      # Default 120.
      attr_writer :auth_challenge_ttl
      def auth_challenge_ttl
        @auth_challenge_ttl ||= 120
      end

      # Per-agent token-revocation watermark store backing `/auth/revoke`
      # ("log out other sessions"). Consulted by {JwtIssuer.verify} on every
      # access-token check. Override with a shared/durable implementation in
      # multi-process deployments; set to nil to disable revocation enforcement.
      #
      # @return [Kiosk::Server::RevocationStore, #revoke_all, #revoked?, nil]
      attr_writer :revocation_store
      def revocation_store
        return @revocation_store if defined?(@revocation_store)

        @revocation_store = Kiosk::Server::RevocationStore.new
      end

      private

      def default_signing_key
        pem = ENV["KIOSK_SIGNING_KEY_PEM"]
        return Kiosk::Server::SigningKey.from_pem(pem) if pem && !pem.empty?

        encoded = ENV["KIOSK_SIGNING_KEY_B64"]
        if encoded && !encoded.empty?
          require "base64"
          return Kiosk::Server::SigningKey.from_pem(Base64.decode64(encoded))
        end

        raise <<~MSG
          KIOSK_SIGNING_KEY_PEM or KIOSK_SIGNING_KEY_B64 is required.

          Generate one with:
            openssl genrsa 2048 | base64

          Then set it in your environment or mise.toml:
            [env]
            KIOSK_SIGNING_KEY_B64 = "LS0tLS1CRUdJTi..."
        MSG
      end
    end
  end
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
