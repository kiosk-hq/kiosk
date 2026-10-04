# frozen_string_literal: true

require "uri"

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

    # Agent-IdP adapter instance — verifies agent tokens (minting through an
    # adapter is a seam, not yet wired; see
    # Kiosk::AgentIdentityProviders::Base#issue). OPTIONAL override: when nil,
    # kiosk-server uses its bundled kiosk-pop engine
    # (`Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp`) — the same
    # engine whose tokens the built-in register/login/revoke endpoints mint,
    # so a zero-config install verifies what it issues. Set this ONLY to front a
    # different agent-identity system (Entra Agent ID, Okta, an ID-JAG-style
    # broker) by subclassing {Kiosk::AgentIdentityProviders::Base}. No demo sets
    # it — the tokens they authenticate are the ones the engine minted.
    attr_accessor :agent_idp

    # Payment PSP adapter instance — captures AP2 cart mandates into PSP
    # settlements (see {Kiosk::PaymentProviders::Base}). Default nil; the
    # provider selects one per market, and `kiosk-pay-stripe` is the only
    # `kiosk-pay-*` adapter this repository ships — `git ls-files
    # 'kiosk-pay-*/*.gemspec'` names it and nothing else.
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

    # The DEFAULT origin this deployment serves (scheme + host + port, no
    # trailing slash): the `iss` of its tokens and mandates, the `aud` a
    # possession proof must carry, and the `issuer` discovery advertises — for
    # every request whose origin is not one of {#additional_origins}. Readers
    # ask `Kiosk.current_issuer`, which answers the origin being served.
    #
    # CONSEQUENCE OF A WRONG VALUE: a total, silent auth outage. The app boots
    # happily, advertises the wrong issuer in discovery, and then rejects EVERY
    # assistant with «proof audience mismatch» — because each one correctly
    # signed the origin it dialed and this value disagrees. Only the operator
    # can fix it; PopVerifier writes the mismatch to the operator log.
    attr_accessor :issuer

    # Further origins this deployment serves, each a separate operator on the
    # wire with its own discovery document and its own assistant accounts.
    # Exact origins only. An alias of the SAME business is better redirected
    # to the issuer at the edge. (Rails' `config.hosts` governs which Host
    # headers are accepted, not which origin the operator is.)
    attr_accessor :additional_origins

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
      @additional_origins = []
    end

    # Every origin served: `[issuer, *additional_origins]`, normalised.
    def origins
      [issuer, *additional_origins].compact.map { |o| self.class.normalize_origin(o) }.compact.uniq
    end

    # The issuer for a request that arrived on `origin`: that origin when it is
    # served, else {#issuer}. The Host only selects among declared origins; it
    # never adds one, so a proof signed for an undeclared origin never verifies.
    def issuer_for(origin)
      normalized = self.class.normalize_origin(origin)
      origins.include?(normalized) ? normalized : issuer
    end

    # Lower-case scheme and host, default port dropped, no path. Nil when
    # `value` is not an absolute http(s) URL.
    def self.normalize_origin(value)
      uri = URI.parse(value.to_s.strip)
      return unless uri.is_a?(URI::HTTP) && uri.host

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    # Full GUC name for one of the four well-known suffix names.
    # Convenience over {Kiosk::GUC.for}(guc_namespace, name).
    def guc(name)
      GUC.for(guc_namespace, name)
    end
  end
end
