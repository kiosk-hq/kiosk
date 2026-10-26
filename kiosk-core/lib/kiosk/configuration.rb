# frozen_string_literal: true

require 'uri'

module Kiosk
  # The settings of an origin, set in `config/initializers/kiosk.rb` with
  # `Kiosk.configure { |c| ... }`. Each setting below says what it does, its
  # default and an example. kiosk-server and the adapter gems add more settings.
  class Configuration
    # The class name of your account model, as a String. Registration makes an
    # account in it for each new assistant, and account binding finds the
    # person's account in it. Required.
    #   c.user_model = 'User'
    attr_accessor :user_model

    # The type of the primary key of `user_model`: :uuid, :bigint, :integer or
    # :text. The kiosk tables and SQL functions store the account id in this
    # type. Default :uuid. A table that Rails made with its default key is :bigint.
    #   c.user_id_type = :bigint
    attr_accessor :user_id_type

    # The adapter that tells which person is signed in on your own site, from
    # the browser session. The account-binding pages read it: the page that
    # makes a link code, the page that approves a device code, and the page
    # that unlinks an assistant. Default nil: these pages refuse every person,
    # so nobody can link an assistant to an account. With Devise, use the
    # adapter of the kiosk-user-idp-devise gem.
    #   c.user_idp = Kiosk::UserIdentityProviders::Devise.new
    attr_accessor :user_idp

    # The adapter that verifies the access token of an assistant on each call.
    # Default nil: kiosk-server verifies the tokens that its own token endpoint
    # issues. Keep the default. Set it only when another system issues the
    # tokens of the assistants. The value is a {Kiosk::AgentIdentityProviders::Base}.
    #   c.agent_idp = MyTokenVerifier.new
    attr_accessor :agent_idp

    # The adapter that charges the card of a customer for a paid action, a
    # {Kiosk::PaymentProviders::Base}. Default nil: the origin takes no money,
    # and discovery does not list `pay`. The kiosk-pay-stripe gem gives Stripe.
    #   c.payment_provider = Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch('STRIPE_SECRET_KEY'))
    attr_accessor :payment_provider

    # The KYC service that confirms facts about a customer, for example an age
    # over 18, a {Kiosk::KycProviders::Base}. Default nil: the action
    # `request_kyc` answers `module_not_served`. The kiosk-kyc-proveli gem gives
    # the Proveli broker.
    #   c.kyc_provider = Kiosk::KycProviders::Proveli.new(operator_id: 'shop',
    #     intake_secret: ENV.fetch('KIOSK_PROVELI_INTAKE_SECRET'), public_key: ENV.fetch('KIOSK_PROVELI_PUBLIC_KEY_PEM'))
    attr_accessor :kyc_provider

    # The Postgres role that the opt-in kiosk-rls gem gives table access to,
    # and that kiosk-server changes to with `SET LOCAL ROLE` when
    # `enforce_db_role` is true. Your database administrator makes the role.
    # Default 'app_role'. Without kiosk-rls and with `enforce_db_role` false
    # (the default), nothing reads it: do not set it.
    #   c.app_role = 'shop_app'
    attr_accessor :app_role

    # The roles that an assistant can get, as Symbols. A token carries one of
    # them, and your code reads it to decide what the assistant can do. Name a
    # role by the job of a person (customer, support), not by a power (admin).
    # Default []: no token carries a role. Most origins need one role,
    # %i[customer]. kiosk-server's `registration_role` names the role that a
    # new assistant gets.
    #   c.roles = %i[customer support]
    attr_accessor :roles

    # The origin of this deployment: scheme, host and port. It is the `iss` of
    # the tokens and checkouts that the engine signs, the `aud` that the proof
    # of an assistant must name, and the `issuer` of discovery. Required.
    # Code reads it with `Kiosk.current_issuer`.
    #   c.issuer = 'https://shop.example'
    attr_accessor :issuer

    # More origins, each a separate operator for the protocol, with its own
    # discovery and its own assistant accounts. Exact origins only. Default [].
    # A second name of the SAME business is better redirected
    # to the issuer at the edge. (Rails' `config.hosts` governs which Host
    # headers are accepted, not which origin the operator is.)
    #   c.additional_origins = ['https://second-shop.example']
    attr_accessor :additional_origins

    def initialize
      @user_id_type       = :uuid
      @app_role           = 'app_role'
      @roles              = []
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

      port = uri.port == uri.default_port ? '' : ":#{uri.port}"
      "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end
  end
end
