# frozen_string_literal: true

module Kiosk
  module Server
    # Adds server-specific fields to {Kiosk::Configuration} via include.
    # Stacks on top of the base Configuration attributes from kiosk-core
    # (`user_model`, `user_id_type`, `guc_namespace`, `schema`, `app_role`,
    # `roles`, `issuer`, …).
    #
    # See the Discovery section of the spec for the well-known shape.
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

      # The handler controllers that declare this origin's wire verbs — the
      # classes that `include Kiosk::Query` / `include Kiosk::Action`. NAME
      # them; Kiosk loads and registers them.
      #
      #   Kiosk.configure do |c|
      #     c.handlers = %w[Kiosk::CatalogController Kiosk::OrdersController]
      #   end
      #
      # A verb registers when its class body is read, and development does not
      # eager-load `app/` — nothing would reference a handler controller,
      # because the wire reaches it THROUGH the registry. Without this list the
      # catalog is empty, the first `query`/`run` 404s, and the discovery
      # documents (whose `capabilities` are computed from the live registry)
      # advertise nothing. The engine drives the list from a `to_prepare` block
      # ({HandlerRegistrations}), so registration is complete at boot in every
      # environment and rebuilt after every reload in development — an edited,
      # added or REMOVED verb all land without a restart.
      #
      # Strings, not constants, are the intended form: the list is re-resolved
      # by name on each reload, and a Class object handed over here belongs to
      # the boot generation. A class is accepted and reduced to its name.
      #
      # Do not rely on eager loading instead of this list. Rails runs the
      # engine's `to_prepare` BEFORE `eager_load!` (Finisher:
      # `run_prepare_callbacks` then `eager_load!`), so in production an
      # unlisted handler still registers — by being read — and appears to work,
      # while the same app in development serves it not at all and every reload
      # drops it again. List every handler controller and the two environments
      # agree.
      attr_writer :handlers
      def handlers
        @handlers ||= []
      end

      # Capabilities the server advertises in `/.well-known/kiosk.json`.
      #
      # Members are MODULE NAMES — the parts of the protocol this origin
      # serves — drawn from the canonical set `schema`, `queries`, `actions`,
      # `pay` and emitted in that order (T-068 slice 5, decision T-075 = A,
      # ADR-0025). Computed from the live registry — NOT a static list — so
      # the document never advertises a module the provider hasn't wired:
      #   * `schema`  — present whenever ≥1 query OR ≥1 action is registered
      #     (schema is the self-description of those).
      #   * `queries` — present iff ≥1 named query is registered.
      #   * `actions` — present iff ≥1 action is registered.
      #   * `pay`     — present iff a payment provider (AP2) is configured.
      #
      # WHY MODULES AND NOT VERB NAMES, since 0.4 gives every verb its own
      # endpoint and "the verbs this endpoint serves" would now be readable
      # literally: enumerating the registered verb names HERE would publish
      # the whole catalog on an UNAUTHENTICATED surface. `GET
      # <endpoint>/schema` is Bearer-gated, {OpenApiController} is Bearer-gated
      # for the same reason, and {VerbController} answers `401` before `404`
      # precisely so an anonymous prober cannot enumerate names. A module set
      # tells an assistant which branches of the skill apply — which is what
      # its Step 1 actually needs — and leaks nothing.
      #
      # HTTP methods are never encoded here: in 0.4 the method follows the
      # KIND of the verb (a query is GET, an action is POST), which the
      # catalog states per verb.
      #
      # A provider may still pin an explicit list via `c.capabilities = [...]`;
      # that override is returned verbatim.
      attr_writer :capabilities
      def capabilities
        return @capabilities if @capabilities

        computed_capabilities
      end

      # Owner block for the well-known document. Free-form hash, e.g.
      # `{ name: ..., support: ... }`. Providers should
      # set at minimum a contact email.
      attr_writer :owner
      def owner
        @owner ||= {}
      end

      # Minimum client version this deployment ADVERTISES in
      # `/.well-known/kiosk.json` (see {WellKnown}). Default:
      # {Kiosk::Protocol::MIN_CLIENT}. Advisory only: no code compares any
      # incoming request's client version against it, so a bump is
      # informational. Note the per-response `Kiosk-Min-Client` header is
      # NOT driven by this value — {Headers} emits the protocol-level
      # {Kiosk::Protocol::MIN_CLIENT} constant, so a bumped provider advertises
      # the new value only in the well-known document, not in the header.
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
        @skill_url ||= "https://kiosk.tech/skill-v0.4.1.md"
      end
      attr_accessor :skill_sha256

      # RSA signing key used by the bundled kiosk-pop IdP to issue and
      # verify JWTs (the account-binding ceremony's token poll mints
      # through the same IdP).
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

      # Removed 2026-07-08 (spec amended: "one PoW = Equihash"). The old
      # SHA256 leading-zero-bits registration hashcash is gone — SHA256 is the
      # most ASIC-optimised hash on Earth, exactly the CPU-hard PoW the ADR
      # drops. Use `registration_pow_count` (Equihash) instead.
      def registration_difficulty=(_)
        raise ArgumentError,
          "registration_difficulty (SHA256 hashcash) was removed — spec amended, " \
          "one PoW = Equihash. Use `c.registration_pow_count = 1` (Equihash) and set " \
          "`c.pow_secret`."
      end

      # Role assigned to every self-registered agent. Self-registration mints a
      # Bearer token with no human in the loop, so the role is pinned by the
      # provider server-side — an agent CANNOT choose its own role (that would
      # be a privilege-selection primitive: the role lands in a transaction-local GUC
      # every RLS policy trusts). Privileged roles are obtainable only through
      # the human-approved device-grant flow.
      #
      # OPTIONAL (roles are hook-or-absent in 0.1, and ADR-0011 is explicit
      # that registration MUST NOT fail when this is unset). When unset,
      # self-registered agents get NO role — `agents.allowed_roles` is the
      # EMPTY array, never NULL, because the shipped migration declares that
      # column `NOT NULL` (K-788) — and a provider that needs roles may
      # assign them inside its
      # `assistant_creation` hook instead. When set, it must be one of {#roles}.
      #   Kiosk.configure { |c| c.registration_role = :customer }
      attr_accessor :registration_role

      # Provider-supplied factory that creates the assistant account backing a
      # self-registered agent. Optional.
      #
      # When set, `AgentRegistration` invokes this proc with ONE argument — the
      # registrant's public key — and USES its RETURN VALUE as the principal
      # (`agents.user_id`). The provider creates its OWN record (satisfying its
      # OWN model validations) and returns that record's id. Because the id
      # comes from the provider's own row, this works for bigint AND uuid PKs;
      # the old framework-generated-uuid contract forced a uuid principal and
      # 500'd on bigint apps. Returning nil raises a ConfigurationError.
      #
      # When unset, registration falls back to `user_model.constantize.create!`
      # (the greenfield default — works only for models without required
      # attributes). A real Rails app with e.g. `validates :email, presence:`
      # should set this hook to avoid a 500 at registration.
      #
      #   Kiosk.configure do |c|
      #     c.assistant_creation = ->(pubkey) do
      #       AssistantAccount.create!(kind: :agent).id
      #     end
      #   end
      attr_accessor :assistant_creation

      # Issuer string of the trusted KYC attestation provider.
      # Must match the `iss` claim of submitted KYC JWS tokens.
      attr_writer :kyc_issuer
      def kyc_issuer
        @kyc_issuer
      end

      # The audience this operator accepts on a KYC attestation — the `aud`
      # claim the KYC provider mints the attestation FOR. {KycVerifier} rejects
      # any attestation whose `aud` does not equal this value, so a claim the
      # broker minted for operator A cannot be replayed to operator B at the
      # WIRE level (not merely by a demo's own callback). Defaults to
      # {#issuer} — the operator's own origin — so a provider that does nothing
      # binds attestations to its origin automatically. An operator whose KYC
      # provider addresses it by a stable handle (rather than its per-deploy
      # origin URL) sets this to that handle.
      attr_writer :kyc_audience
      def kyc_audience
        @kyc_audience || issuer
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

      # Storage adapter for {Kiosk::Server::DeviceAuthorization} rows (the
      # account-binding ceremony state machine). Lazy default: the durable
      # {DeviceAuthorizationStores::ActiveRecord} store (over
      # `kiosk.device_authorizations`, migration 008) — the ceremony is
      # cross-process by nature (the human approves in a browser while the
      # agent polls from another process), so an in-memory store cannot serve
      # it. {DeviceAuthorizationStores::InMemory} stays shipped for tests and
      # is assigned explicitly through the writer.
      #
      # @return [DeviceAuthorizationStores::Base]
      attr_writer :device_authorization_store
      def device_authorization_store
        @device_authorization_store ||=
          Kiosk::Server::DeviceAuthorizationStores::ActiveRecord.new
      end

      # Operator sign-in path the engine redirects a browser to when an
      # UNAUTHENTICATED human hits the manage-assistants page
      # (`<mount>/auth/assistants`). Optional, default nil.
      #
      # The engine stays IdP-neutral — it cannot hardcode a sign-in URL
      # (Devise's `/users/sign_in` is app-specific). When a provider sets this
      # to its own sign-in path, {AssistantsController#require_account_holder!}
      # redirects a browser visitor there (with a flash alert + a stored
      # return-to) instead of rendering the bare 401. When left nil — or for a
      # non-HTML/API request — the plain 401 is preserved, so the API contract
      # is unaffected.
      attr_accessor :sign_in_path

      # ── Account-binding hooks ──────────────────────────────────

      # Optional callable fired when a KNOWN key is claimed onto (rebound to)
      # an assistant-account holder's account — scenario TWO's upgrade path.
      # Invoked with keywords `(agent:, previous_user_id:, user_id:)` inside
      # the rebind transaction, so a raising hook rolls the rebind back.
      # Core never touches provider-domain rows (satellite neutrality); this
      # hook is where the vertical adopts/migrates the old standalone
      # account's domain data if it wants to. Default nil (no-op).
      attr_accessor :assistant_claimed

      # Optional callable fired when a binding is deactivated via
      # POST /auth/unlink (registration-layer revocation). Invoked with
      # keywords `(agent:, user_id:)` after the agent row is deactivated
      # and its tokens are watermark-revoked. Default nil (no-op).
      attr_accessor :assistant_unlinked

      # ── Per-assistant spending cap ─────────────────────────────

      # Optional callable returning the spending cap (in cents) for an assistant,
      # or nil for no cap. Invoked `(agent_id:) → Integer | nil` in the pay path
      # BEFORE the irreversible PSP capture; a cap of 0 disables the assistant's
      # payments entirely. Default nil = the feature is off (no enforcement, no
      # lookup — existing behaviour unchanged). A ready-made column-backed
      # implementation is {Kiosk::Server::ColumnSpendingCap} (reads
      # `agents.spending_cap_cents`, the column edited by the manage-assistants
      # page); a provider storing caps elsewhere supplies its own callable.
      attr_accessor :spending_cap

      # Rolling window in days over which settled spend is summed against the
      # cap. Default nil = all-time cumulative. E.g. 7 for a weekly allowance.
      attr_accessor :spending_cap_window_days

      # ── Request-shape validation (opt-in; UNIFORM-VALIDATION slice-1) ─────

      # When true, {WireController} validates a PRESENT `pow` field on a wire
      # request against the vendored normative PoW schema BEFORE {PowGate.gate}
      # consumes it, and rejects a malformed shape with a `bad_request` (400)
      # carrying a hint naming the expected shape — instead of the K-479 silent
      # re-challenge loop (a malformed pow whose proofs {PowGate.extract_proofs}
      # cannot parse yields [], so the gate re-issues a fresh 402 forever with no
      # diagnostic). Default false = byte-identical old behaviour.
      #
      # This is a SHAPE check in front of the gate — NOT a replacement for it: a
      # well-formed-but-forged proof still fails the real cryptographic
      # verification inside the gate. An ABSENT pow is untouched (the initial
      # no-pow request still gets its normal 402 challenge). Requires the OPTIONAL
      # `json_schemer` gem; if this is on but the gem is not loadable, the first
      # validation raises a {Errors::ConfigurationError} naming it. The demos turn
      # this on; the fuller uniform-validation layer is v0.5 (T-045).
      attr_writer :validate_requests
      def validate_requests
        @validate_requests ||= false
      end

      # When true, every query/action answer is validated against the
      # `output_schema` that verb DECLARES, and a mismatch raises — see
      # {ResponseValidation} for why the check exists and where it runs.
      #
      # DEFAULT FALSE, and deliberately NOT the flag above. `validate_requests`
      # polices what a CALLER sent; this polices what the OPERATOR's own handler
      # rendered. Nothing a caller does can trigger it, the failure it reports is
      # always an operator-side bug, and it costs one schema validation per
      # answer — so it belongs in development and CI, where a descriptor that
      # lies about its handler is cheap to fix, and not in front of a production
      # caller who did nothing wrong. Requires the OPTIONAL `json_schemer` gem
      # on the same terms as `validate_requests`.
      attr_writer :validate_responses
      def validate_responses
        @validate_responses ||= false
      end

      # ── PoW challenge-response gate (R2) ──────────────────────────────────

      # Reputation policy that decides when and how hard to challenge a request.
      # Default nil = never challenge (zero overhead; existing behaviour unchanged).
      # Set to a `Kiosk::Reputation::Policy` instance (or any object responding to
      # `#challenge_for(identity:, verb:, factors:) → {alg:,params:,count:}|nil`
      # (`count` is the N×PoW proof-count escalation lever; the gate defaults it
      # to 1 when omitted).
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

      # In-process TTL store for spent challenge ids. A multi-process
      # deployment (`WEB_CONCURRENCY > 1`, or several app hosts) **MUST**
      # override this with a store shared by every process — with the default,
      # PoW single-use holds per worker, so one proof is accepted once per
      # worker (K-738; protocol.md Section 15.2 + the Section 16.1 operator
      # profile state the requirement). {Kiosk::Server::PowSpentStores::ActiveRecord}
      # ships as the ready override. The override MUST implement #claim as ONE
      # atomic op (Redis SETNX / SQL INSERT..ON CONFLICT) — the gate claims
      # before the verify, so a read-then-write reintroduces the replay TOCTOU
      # (K-542).
      #
      # @return [Kiosk::Server::PowSpentStore, #claim(id, exp), #release(id), #spent?(id), #mark_spent(id, exp)]
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
      #
      # At registration the agent must ALSO solve the Equihash PoW
      # (`registration_pow_count` proofs) inside this same window before it can
      # POST /auth/register. The PoW solve window is `pow_ttl * count` (see
      # PowGate#issue_challenges). The old flat 120s default was SHORTER than a
      # single-proof PoW window (pow_ttl = 300s), so a legitimate slow solver's
      # auth nonce expired mid-solve — and the burned PoW proofs were already
      # spent. The default now DERIVES from the PoW window so it always exceeds
      # it (with 60s headroom), and scales when a provider raises `pow_ttl` or
      # `registration_pow_count`. Set explicitly to override.
      attr_writer :auth_challenge_ttl
      def auth_challenge_ttl
        @auth_challenge_ttl ||= pow_ttl * [registration_pow_count.to_i, 1].max + 60
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

      # Compute the advertised module list from the live registry, in the
      # canonical order schema, queries, actions, pay. See {#capabilities}.
      #
      # The COMPUTATION is unchanged from the verb-name era — same three
      # questions of the same registry — only the names it emits moved from
      # verbs to modules.
      def computed_capabilities
        has_queries = Kiosk::Server::Queries.known.any?
        has_actions = Kiosk::Server::Actions.known.any?
        has_pay     = !payment_provider.nil?

        caps = []
        caps << "schema"  if has_queries || has_actions
        caps << "queries" if has_queries
        caps << "actions" if has_actions
        caps << "pay"     if has_pay
        caps.freeze
      end

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
