# frozen_string_literal: true

module Kiosk
  module Server
    # Server settings, added to {Kiosk::Configuration}.
    module ConfigurationExtension
      # Serialises the first touch of each lazy store slot, so racing threads
      # cannot each build their own store (a double-spent proof of work).
      LAZY_STORE_MUTEX = Mutex.new

      # The discovery settings: where the protocol is mounted and what it advertises.
      module Discovery
        # Default `/kiosk`. Discovery advertises `endpoint = origin + mount_path`.
        attr_writer :mount_path

        def mount_path
          @mount_path ||= Kiosk::Protocol::DEFAULT_MOUNT_PATH
        end

        # Module names advertised in `/.well-known/kiosk.json`. Computed from what
        # is registered and configured. An operator cannot set them.
        def capabilities
          computed_capabilities
        end

        # Free-form owner block for discovery, e.g. `{ name:, support: }`.
        attr_writer :owner

        def owner
          @owner ||= {}
        end

        # The skill this origin was built against. Discovery emits the `skill`
        # block only when `skill_sha256` is set.
        attr_writer :skill_url

        def skill_url
          @skill_url ||= 'https://kiosk.tech/skill-v0.6.11.md'
        end
        attr_accessor :skill_sha256

        private

        # The spec's order; `events` stays last.
        def computed_capabilities
          has_queries = Kiosk::Server::Queries.known.any?
          has_actions = Kiosk::Server::Actions.known.any?
          {
            'schema' => has_queries || has_actions,
            'queries' => has_queries,
            'actions' => has_actions,
            'pay' => !payment_provider.nil?,
            'events' => Kiosk::Server::Events.known.any?
          }.select { |_, served| served }.keys.freeze
        end
      end

      # The proof-of-work settings: registration proofs and the reputation challenge.
      module ProofOfWork
        # Equihash proofs asked at `POST /oauth/register`, at the link-code claim and
        # at the first token poll of each device code, at the gem's default params.
        # Default 0 (open). Above 0 needs `pow_secret` and `kiosk-pow-equihash`.
        attr_writer :registration_pow_count

        def registration_pow_count
          @registration_pow_count ||= 0
        end

        # Decides when and how hard to challenge. Default nil: never.
        # `#challenge_for(identity:, verb:, factors:) → {alg:, params:, count:} | nil`;
        # the verb it receives is `:run`, never `:action`.
        def reputation_policy=(value)
          VerbVocabulary.assert!(value, :challenge_for, 'reputation_policy #challenge_for') unless value.nil?
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
                  'Generate one with `openssl rand -hex 32`.'
          end

          @pow_secret = value
        end

        # Seconds. Default 300.
        attr_writer :pow_ttl

        def pow_ttl
          @pow_ttl ||= 300
        end
      end

      # The anonymized-KYC attestation settings.
      module Kyc
        # Anonymized attributes gated actions need, e.g. %w[age_over_18].
        attr_writer :kyc_claims

        def kyc_claims
          @kyc_claims || []
        end
      end

      # The database settings: where Kiosk's tables live and how a request reaches them.
      module Database
        # Postgres schema for Kiosk's own tables and functions. Default 'kiosk'.
        attr_writer :schema

        def schema
          @schema ||= 'kiosk'
        end

        # Prefix of the session GUCs a request sets, e.g. `app.user_id`. Default 'app'.
        attr_writer :guc_namespace

        def guc_namespace
          @guc_namespace ||= Kiosk::GUC::DEFAULT_NAMESPACE
        end

        # When true, every request transaction runs `SET LOCAL ROLE <app_role>`;
        # that role then needs grants on every table the verbs touch. Default false.
        attr_writer :enforce_db_role

        def enforce_db_role
          @enforce_db_role ||= false
        end
      end

      include Discovery
      include ProofOfWork
      include Kyc
      include Database

      # Required. A SigningKey or the PEM string of an Ed25519 key.
      def signing_key
        @signing_key || raise(Errors::ConfigurationError,
                              "c.signing_key is not set. #{SigningKey::HINT.capitalize}.")
      end

      def signing_key=(value)
        @signing_key = signing_key_from(value, 'signing_key')
      end

      # Optional. The key that signed before {#signing_key}: the JWKS still
      # publishes it, and a token or checkout it signed still verifies. A public
      # PEM is enough. Keep it for at least one access-token lifetime, and while
      # a checkout it signed can still be paid.
      attr_reader :previous_signing_key

      def previous_signing_key=(value)
        @previous_signing_key = signing_key_from(value, 'previous_signing_key')
      end

      # The keys the JWKS publishes and verification accepts, the current one first.
      def signing_keys = [signing_key, previous_signing_key].compact

      # The JOSE algorithms an AI assistant can sign with. Default `["EdDSA"]`:
      # Ed25519 keys only. `%w[EdDSA ES256]` also accepts P-256 keys.
      def assistant_algorithms
        @assistant_algorithms || [Eddsa::NAME]
      end

      def assistant_algorithms=(value)
        algorithms = Array(value).map(&:to_s)
        valid = [[Eddsa::NAME], [Eddsa::NAME, 'ES256']].include?(algorithms)
        raise Errors::ConfigurationError, "c.assistant_algorithms is %w[EdDSA] or %w[EdDSA ES256], got #{algorithms.inspect}" unless valid

        @assistant_algorithms = algorithms.freeze
      end

      # The role every registered client is pinned to, and the default a
      # binding falls back to. Required, and one of {#roles}, when {#roles} is set.
      #   Kiosk.configure { |c| c.roles = %i[customer]; c.registration_role = :customer }
      attr_accessor :registration_role

      # Optional `->(public_key_pem) { record_id }` creating the account behind a
      # registered client. Unset: `user_model.constantize.create!`.
      attr_accessor :assistant_creation

      # Account-binding ceremony state. Default: the shared database store.
      attr_writer :device_authorization_store

      def device_authorization_store
        @device_authorization_store ||
          LAZY_STORE_MUTEX.synchronize do
            @device_authorization_store ||=
              Kiosk::Server::DeviceAuthorizationStores::ActiveRecord.new
          end
      end

      # Per-identity event tail. Default: the shared database table.
      attr_writer :event_store

      def event_store
        @event_store ||
          LAZY_STORE_MUTEX.synchronize { @event_store ||= Kiosk::Server::EventStores::ActiveRecord.new }
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

      # Called as `(agent:, from:, to:)` when an assistant's client moves from one
      # account to another, inside the rebind transaction: the place to move
      # the operator's own rows. `from` and `to` are `user_model` records.
      attr_accessor :assistant_claimed

      # Called as `(agent:, account:)` after an assistant is unlinked from
      # `account`, a `user_model` record, and its tokens are revoked.
      attr_accessor :assistant_unlinked

      # Optional `(agent_id:) → { amount_cents:, currency: } | nil`, checked
      # before capture; 0 blocks payments, and so does a checkout in another currency.
      # {Kiosk::Server::ColumnSpendingCap} reads
      # `agents.spending_cap_cents`, the column edited by the manage-assistants
      # page, and `agents.spending_cap_currency`.
      attr_accessor :spending_cap

      # Days of settled spend summed against the cap. Default nil: all time.
      attr_accessor :spending_cap_window_days

      # `call(id, lines) → cents | String`: the payable row's price, or why the checkout is refused.
      attr_accessor :checkout_price_checker

      # Optional `call(id)`, run once the settlement that paid row `id` is recorded.
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
                'audit_sink must be callable (a lambda or any object answering #call) ' \
                "or nil to emit nothing, got #{value.class}"
        end

        @audit_sink = value
      end

      # Spent ids, so a proof-of-work proof or a client assertion is accepted once.
      # Default: the shared database table.
      attr_writer :pow_spent_store

      def pow_spent_store
        @pow_spent_store ||
          LAZY_STORE_MUTEX.synchronize { @pow_spent_store ||= Kiosk::Server::PowSpentStores::ActiveRecord.new }
      end

      # Seconds an access token lives. Default 3600.
      attr_writer :access_token_ttl

      def access_token_ttl
        @access_token_ttl ||= JwtIssuer::DEFAULT_EXPIRES_IN
      end

      # Revocation watermarks, checked on every access token. Default: the
      # shared database table, so a revoke or an unlink holds in every process.
      attr_writer :revocation_store

      def revocation_store
        @revocation_store ||
          LAZY_STORE_MUTEX.synchronize { @revocation_store ||= Kiosk::Server::RevocationStores::ActiveRecord.new }
      end

      private

      def signing_key_from(value, name)
        case value
        when Kiosk::Server::SigningKey, nil then value
        when String then Kiosk::Server::SigningKey.from_pem(value)
        else raise ArgumentError, "#{name} must be a SigningKey or PEM string, got #{value.class}"
        end
      end
    end
  end
end
