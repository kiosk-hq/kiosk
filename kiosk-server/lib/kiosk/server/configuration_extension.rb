# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/verb_vocabulary"

module Kiosk
  module Server
    # Server settings, added to {Kiosk::Configuration}.
    module ConfigurationExtension
      # Serialises the first touch of each lazy store slot, so racing threads
      # cannot each build their own store (a double-spent proof of work).
      LAZY_STORE_MUTEX = Mutex.new

      # Default `/kiosk`. Discovery advertises `endpoint = origin + mount_path`.
      attr_writer :mount_path
      def mount_path
        @mount_path ||= Kiosk::Protocol::DEFAULT_MOUNT_PATH
      end

      # When true, every request transaction runs `SET LOCAL ROLE <app_role>`;
      # that role then needs grants on every table the verbs touch. Default false.
      attr_writer :enforce_db_role
      def enforce_db_role
        @enforce_db_role ||= false
      end

      # Module names advertised in `/.well-known/kiosk.json`. Default: computed
      # from what is registered and configured; a set value is returned verbatim.
      attr_writer :capabilities
      def capabilities
        return @capabilities if @capabilities

        computed_capabilities
      end

      # Free-form owner block for discovery, e.g. `{ name:, support: }`.
      attr_writer :owner
      def owner
        @owner ||= {}
      end

      # Advertised in discovery and the `Kiosk-Min-Client` header. Advisory only.
      attr_writer :min_client
      def min_client
        @min_client ||= Kiosk::Protocol::MIN_CLIENT
      end

      # The skill this origin was built against. Discovery emits the `skill`
      # block only when `skill_sha256` is set.
      attr_writer :skill_url
      def skill_url
        @skill_url ||= "https://kiosk.tech/skill-v0.5.12.md"
      end
      attr_accessor :skill_sha256

      # Required. A SigningKey or a PEM string.
      def signing_key
        @signing_key || raise(Errors::ConfigurationError,
                              "c.signing_key is not set. Generate one with `openssl genrsa 2048`.")
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

      # Equihash proofs required at `POST /auth/register`. Default 0 (open).
      # Above 0 needs `pow_secret` and `kiosk-pow-equihash`.
      attr_writer :registration_pow_count
      def registration_pow_count
        @registration_pow_count ||= 0
      end

      # Equihash (n, k) for registration. Default nil: the gem's own params.
      attr_accessor :registration_pow_params

      def registration_difficulty=(_)
        raise ArgumentError,
          "registration_difficulty (SHA256 hashcash) was removed — spec amended, " \
          "one PoW = Equihash. Use `c.registration_pow_count = 1` (Equihash) and set " \
          "`c.pow_secret`."
      end

      # The role every self-registered agent is pinned to, and the default a
      # binding falls back to. Required, and one of {#roles}, when {#roles} is set.
      #   Kiosk.configure { |c| c.roles = %i[customer]; c.registration_role = :customer }
      attr_accessor :registration_role

      # Optional `->(public_key) { record_id }` creating the account behind a
      # self-registered agent. Unset: `user_model.constantize.create!`.
      attr_accessor :assistant_creation

      # Anonymized attributes gated actions need, e.g. %w[age_over_18].
      attr_writer :kyc_claims
      def kyc_claims
        @kyc_claims || []
      end

      # Must match the `iss` of submitted KYC attestations.
      attr_writer :kyc_issuer
      def kyc_issuer
        @kyc_issuer
      end

      # The `aud` a KYC attestation must carry. Default: the origin being served.
      attr_writer :kyc_audience
      def kyc_audience
        @kyc_audience || Kiosk.current_issuer
      end

      # The KYC provider's RSA key: an OpenSSL::PKey or a PEM string.
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

      # Account-binding ceremony state. Default: the shared database store.
      attr_writer :device_authorization_store
      def device_authorization_store
        @device_authorization_store ||
          LAZY_STORE_MUTEX.synchronize do
            @device_authorization_store ||=
              Kiosk::Server::DeviceAuthorizationStores::ActiveRecord.new
          end
      end

      # Per-identity event tail. The default is in-process and lost on restart;
      # a production origin with event topics must set
      #   c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
      attr_writer :event_store
      def event_store
        @event_store ||
          LAZY_STORE_MUTEX.synchronize { @event_store ||= Kiosk::Server::EventStore.new }
      end

      # Optional sign-in path a browser is redirected to from the assistants and
      # verify pages. Unset, or for an API request: a plain 401.
      attr_accessor :sign_in_path

      # Default true. False answers every binding path `501 module_not_served`.
      attr_writer :serve_account_binding
      def serve_account_binding
        return @serve_account_binding unless @serve_account_binding.nil?

        true
      end

      # Called as `(agent:, from:, to:)` when an assistant's key moves from one
      # account to another, inside the rebind transaction: the place to move
      # the operator's own rows. `from` and `to` are `user_model` records.
      attr_accessor :assistant_claimed

      # Called as `(agent:, account:)` after an assistant is unlinked from
      # `account`, a `user_model` record, and its tokens are revoked.
      attr_accessor :assistant_unlinked

      # Optional `(agent_id:) → cents | nil`, checked before capture; 0 blocks payments.
      # {Kiosk::Server::ColumnSpendingCap} reads
      # `agents.spending_cap_cents`, the column edited by the manage-assistants
      # page.
      attr_accessor :spending_cap

      # Days of settled spend summed against the cap. Default nil: all time.
      attr_accessor :spending_cap_window_days

      # `call(id, lines) → cents | String`: the payable row's price, or why the cart is refused.
      attr_accessor :cart_price_checker

      # Optional `call(id)`, run once the capture for row `id` has returned.
      attr_accessor :after_payment

      # Default true. Malformed `Kiosk-PoW` and reserved-endpoint bodies are a 400
      # naming the problem, rather than an endless re-challenge.
      attr_writer :validate_requests
      def validate_requests
        return @validate_requests unless @validate_requests.nil?

        true
      end

      # Default false. Checks each answer against its verb's `output_schema`
      # and raises on mismatch: an operator-side bug, so for development and CI.
      attr_writer :validate_responses
      def validate_responses
        @validate_responses ||= false
      end

      # Optional callable receiving one {Kiosk::Server::ActionEvent} per action
      # invocation, arguments unredacted. Default nil: nothing is emitted.
      # A sink that raises does not fail the action.
      attr_reader :audit_sink

      def audit_sink=(value)
        if !value.nil? && !value.respond_to?(:call)
          raise ArgumentError,
                "audit_sink must be callable (a lambda or any object answering #call) " \
                "or nil to emit nothing, got #{value.class}"
        end

        @audit_sink = value
      end

      # Decides when and how hard to challenge. Default nil: never.
      # `#challenge_for(identity:, verb:, factors:) → {alg:, params:, count:} | nil`;
      # the verb it receives is `:run`, never `:action`.
      def reputation_policy=(value)
        VerbVocabulary.assert!(value, :challenge_for, "reputation_policy #challenge_for") unless value.nil?
        @reputation_policy = value
      end

      def reputation_policy
        @reputation_policy
      end

      # HMAC key for proof-of-work challenges, at least 32 bytes.
      attr_reader :pow_secret

      def pow_secret=(value)
        if value.to_s.bytesize < 32
          raise Errors::ConfigurationError,
                "c.pow_secret must be at least 32 bytes (got #{value.to_s.bytesize}). " \
                "Generate one with `openssl rand -hex 32`."
        end

        @pow_secret = value
      end

      # Seconds. Default 300.
      attr_writer :pow_ttl
      def pow_ttl
        @pow_ttl ||= 300
      end

      # `(identity:, verb:) → Kiosk::Reputation::Factors`. Default: empty factors.
      def reputation_factors=(value)
        VerbVocabulary.assert!(value, nil, "reputation_factors callable") unless value.nil?
        @reputation_factors = value
      end

      def reputation_factors
        @reputation_factors ||= ->(**) { ::Kiosk::Reputation::Factors.empty }
      end

      # `(identity:)`, called on a cryptographically invalid proof. Default: no-op.
      attr_writer :on_bad_proof
      def on_bad_proof
        @on_bad_proof ||= ->(**) {}
      end

      # Spent challenge ids, so a proof is accepted once. Default: the shared database table.
      attr_writer :pow_spent_store
      def pow_spent_store
        @pow_spent_store ||
          LAZY_STORE_MUTEX.synchronize { @pow_spent_store ||= Kiosk::Server::PowSpentStores::ActiveRecord.new }
      end

      # Outstanding auth nonces. The default is in-process; a multi-process
      # deployment needs {AuthChallengeStores::ActiveRecord} (§15.2).
      attr_writer :auth_challenge_store
      def auth_challenge_store
        @auth_challenge_store ||
          LAZY_STORE_MUTEX.synchronize { @auth_challenge_store ||= Kiosk::Server::AuthChallengeStore.new }
      end

      # Seconds between `GET /auth/challenge` and the signed POST. Default covers
      # the registration proof-of-work window plus 60s.
      attr_writer :auth_challenge_ttl
      def auth_challenge_ttl
        @auth_challenge_ttl ||= pow_ttl * [registration_pow_count.to_i, 1].max + 60
      end

      # Revocation watermarks, checked on every access token. nil disables
      # revocation. Implement `watermark_for` too, or same-second rebinds leak (§6.3).
      attr_writer :revocation_store
      def revocation_store
        # nil is a meaningful value here, so `defined?` rather than truthiness.
        return @revocation_store if defined?(@revocation_store)

        LAZY_STORE_MUTEX.synchronize do
          return @revocation_store if defined?(@revocation_store)

          @revocation_store = Kiosk::Server::RevocationStore.new
        end
      end

      private

      # The spec's order; `events` stays last.
      def computed_capabilities
        has_queries = Kiosk::Server::Queries.known.any?
        has_actions = Kiosk::Server::Actions.known.any?
        has_pay     = !payment_provider.nil?
        has_events  = Kiosk::Server::Events.known.any?

        caps = []
        caps << "schema"  if has_queries || has_actions
        caps << "queries" if has_queries
        caps << "actions" if has_actions
        caps << "pay"     if has_pay
        caps << "events"  if has_events
        caps.freeze
      end
    end
  end
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
