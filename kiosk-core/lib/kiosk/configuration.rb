# frozen_string_literal: true

module Kiosk
  # Holds host-application choices: which user model, which IdP adapters,
  # which GUC namespace, role vocabulary, issuer URL.
  #
  # Filled via `Kiosk.configure { |c| ... }`. Sensible defaults for a
  # greenfield Rails app with the bundled agent-IdP and a stub user model.
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
    # service account, team / org, or parent agent (see spec §6.1).
    # Default nil; `kiosk:install` wires one based on detected stack
    # (Devise / Clerk / Auth0 / generic OIDC / etc.).
    attr_accessor :user_idp

    # Agent-IdP adapter instance — mints / verifies agent tokens.
    # Default nil here; `kiosk-server` defaults to `DefaultAgentIdp`.
    attr_accessor :agent_idp

    # Payment PSP adapter instance — handles authorize / capture / refund of
    # AP2 mandates (see {Kiosk::PaymentProviders::Base}). Default nil; the
    # provider selects one per market (kiosk-pay-stripe, kiosk-pay-paddle, …).
    attr_accessor :payment_provider

    # Postgres GUC namespace (see {Kiosk::GUC}). Default "app".
    attr_accessor :guc_namespace

    # Postgres schema where Kiosk's own tables (agents, intent/cart/payment
    # mandates, settlements, events) and helper functions live. Default
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
    # (see spec §7.1.X — job-titled roles beat privilege-titled ones).
    attr_accessor :roles

    # Canonical issuer URL — used in JWT `iss` claim and AP2 mandate `iss`.
    # MUST equal `kiosk.issuer` advertised in `/.well-known/kiosk.json`.
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
