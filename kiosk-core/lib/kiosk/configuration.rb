# frozen_string_literal: true

require "uri"

module Kiosk
  # Host-application settings, filled via `Kiosk.configure`. Defaults suit a greenfield
  # Rails app on the bundled agent-IdP; the provider supplies its own user
  # model and (optionally) a user-IdP adapter.
  class Configuration
    # Class name as a String, resolved at request time.
    attr_accessor :user_model

    # :uuid (default), :bigint, :integer or :text.
    attr_accessor :user_id_type

    attr_accessor :user_id_column

    # Nil in satellite mode: the provider's own frontend drives the wire endpoints.
    attr_accessor :user_idp

    # Nil uses kiosk-server's bundled DefaultAgentIdp; set only to front another agent-identity system.
    attr_accessor :agent_idp

    # A {Kiosk::PaymentProviders::Base}; nil means no payment.
    attr_accessor :payment_provider

    # A {Kiosk::KycProviders::Base}; nil makes `request_kyc` answer `module_not_served`.
    attr_accessor :kyc_provider

    attr_accessor :guc_namespace

    # Postgres schema for Kiosk's own tables and functions.
    attr_accessor :schema

    # Runtime DB role named in kiosk-rls GRANTs and `SET LOCAL ROLE`; the DBA creates it.
    attr_accessor :app_role

    # E.g. `%i[customer master support]`. Never `:admin`.
    attr_accessor :roles

    # The default origin served: `iss` of tokens and mandates, required proof `aud`,
    # discovery `issuer`. Readers ask `Kiosk.current_issuer`.
    attr_accessor :issuer

    # Further origins, each a separate operator on the wire. Exact origins only;
    # an alias of the SAME business is better redirected
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
      @kyc_provider     = nil
      @guc_namespace    = GUC::DEFAULT_NAMESPACE
      @schema           = "kiosk"
      @app_role         = "app_role"
      @roles            = []
      @issuer           = nil
      @additional_origins = []
    end

    def origins
      [issuer, *additional_origins].compact.map { |o| self.class.normalize_origin(o) }.compact.uniq
    end

    # The Host only selects among declared origins; it never adds one.
    def issuer_for(origin)
      normalized = self.class.normalize_origin(origin)
      origins.include?(normalized) ? normalized : issuer
    end

    # Lower-case scheme and host, default port dropped; nil unless an absolute http(s) URL.
    def self.normalize_origin(value)
      uri = URI.parse(value.to_s.strip)
      return unless uri.is_a?(URI::HTTP) && uri.host

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def guc(name)
      GUC.for(guc_namespace, name)
    end
  end
end
