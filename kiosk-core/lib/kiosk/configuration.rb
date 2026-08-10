# frozen_string_literal: true

module Kiosk
  # Holds host-application choices: which user model, which IdP adapters,
  # which GUC namespace, role vocabulary, issuer URL.
  #
  # Filled via `Kiosk.configure { |c| ... }`. Defaults suit a greenfield
  # Rails app on the bundled agent-IdP; the provider supplies its own user
  # model and (optionally) a user-IdP adapter.
  class Configuration
    # Provider's user model class name as a String — resolved at request time
    # by kiosk-server, not eagerly, to avoid load-order issues.
    attr_accessor :user_model

    # Type of `users.id` — :uuid (default), :bigint, :integer, or :text.
    attr_accessor :user_id_type

    # Column name on `users` that holds the principal id. Default :id.
    attr_accessor :user_id_column

    # User-IdP adapter instance — consumes the provider's principal
    # authentication. The principal may be a human, synthetic placeholder,
    # service account, team / org, or parent agent.
    # Default nil (satellite mode: the provider's own frontend drives the
    # wire endpoints). `kiosk:install` writes a commented-out
    # `Kiosk::UserIdentityProviders::Devise.new` line to uncomment when the
    # kiosk-user-idp-devise adapter is installed.
    attr_accessor :user_idp

    # Agent-IdP adapter instance — verifies agent tokens (and, from 0.2,
    # mints them). OPTIONAL override: when nil,
    # kiosk-server uses its bundled kiosk-pop engine
    # (`Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp`) — the same
    # engine whose tokens the built-in register/login/revoke endpoints mint,
    # so a zero-config install verifies what it issues. Set this to front a
    # different agent-identity system or to compose (see the demos'
    # JwtOrStubIdp).
    attr_accessor :agent_idp

    # Payment PSP adapter instance — captures AP2 cart mandates into PSP
    # settlements (see {Kiosk::PaymentProviders::Base}). Default nil; the
    # provider selects one per market (kiosk-pay-stripe today; further
    # kiosk-pay-* adapters planned).
    attr_accessor :payment_provider

    # Postgres GUC namespace (see {Kiosk::GUC}). Default "app".
    attr_accessor :guc_namespace

    # Postgres schema where Kiosk's own tables (agents, intent/cart/payment
    # mandates, settlements) and helper functions live. Default
    # "kiosk". Overridable for providers whose primary backend already uses
    # a `kiosk` schema for its own purposes.
    attr_accessor :schema

    # Runtime DB role Kiosk references by name — in `GRANT ... TO <role>`
    # statements emitted by the opt-in kiosk-rls DSL, and in `SET LOCAL
    # ROLE` when kiosk-server's `enforce_db_role` is on. Kiosk does NOT
    # create the role; the provider's DBA does. Default "app_role".
    attr_accessor :app_role

    # Fixed set of role names the provider supports.
    # E.g. `%i[customer master support]`. Never include `:admin`
    # (job-titled roles beat privilege-titled ones).
    attr_accessor :roles

    # Canonical issuer URL — used in the JWT `iss` claim and the AP2 mandate
    # `iss`. MUST equal `kiosk.issuer` advertised in
    # `/.well-known/kiosk.json`, and MUST be the origin assistants actually
    # dial (scheme + host + port, no trailing slash).
    #
    # WHY IT IS CONFIGURED AND NOT DERIVED FROM THE REQUEST HOST. This value
    # is an anchor twice over, and both uses need it to be a fact about the
    # deployment rather than a fact about the incoming request:
    #
    #   * AP2 anchor — it is the `iss` a mandate is signed under. Mandates
    #     outlive the request that minted them, so the identity they name has
    #     to be the operator's, not whatever Host header happened to arrive.
    #   * Origin-binding anchor — `PopVerifier` requires the assistant's
    #     proof-of-possession JWS to carry `aud` equal to this value by STRICT
    #     equality. That is the relay defense: a proof minted for provider M
    #     cannot be replayed at provider L because L checks `aud == L`. Derived
    #     from the request host it would defend nothing — an attacker sets the
    #     Host header, and the check compares the request against itself.
    #
    # CONSEQUENCE OF A WRONG VALUE: a total, silent auth outage. The app boots
    # happily, advertises the wrong issuer in discovery, and then rejects EVERY
    # assistant with «proof audience mismatch» — because each one correctly
    # signed the origin it dialed and this value disagrees. Nothing is
    # recoverable client-side; only the operator can fix it. Check the
    # operator log for the audience-mismatch diagnostic PopVerifier writes.
    #
    # ONE INSTANCE SERVES EXACTLY ONE ORIGIN, by construction: the equality
    # check accepts a single value, so vanity/alias hostnames must redirect to
    # the canonical origin BEFORE any Kiosk verb, and hosting a second merchant
    # means a second instance. (Rails' `config.hosts` does not help here — it
    # governs which Host headers are ACCEPTED, not which origin the provider
    # IS.) Per-host issuer resolution is the recorded 0.2 direction (K-507);
    # 0.1 ships the one-origin behaviour described above.
    attr_accessor :issuer

    def initialize
      @user_model       = nil
      @user_id_type     = :uuid
      @user_id_column   = :id
      @user_idp         = nil
      @agent_idp        = nil
      @payment_provider = nil
      @guc_namespace    = GUC::DEFAULT_NAMESPACE
      @schema           = "kiosk"
      @app_role         = "app_role"
      @roles            = []
      @issuer           = nil
    end

    # Full GUC name for one of the four well-known suffix names.
    # Convenience over {Kiosk::GUC.for}(guc_namespace, name).
    def guc(name)
      GUC.for(guc_namespace, name)
    end
  end
end
