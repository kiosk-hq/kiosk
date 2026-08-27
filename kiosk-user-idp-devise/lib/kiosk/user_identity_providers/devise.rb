# frozen_string_literal: true

require "kiosk"

module Kiosk
  module UserIdentityProviders
    # Devise user-IdP adapter — an opt-in {Kiosk::UserIdentityProviders::Base}
    # implementation for Rails providers that authenticate principals through
    # Devise. Add `kiosk-user-idp-devise` to the Gemfile explicitly; the
    # `kiosk-all` meta-gem bundles only `kiosk-core` and `kiosk-server`, so
    # IdP adapters are chosen per provider.
    #
    # The adapter is agnostic about HOW the user logged in: Devise's
    # `database_authenticatable` and `omniauthable` modules both populate the
    # request's Warden user, so the same read covers password login,
    # passwordless magic-link, and any OmniAuth strategy (Google, GitHub,
    # SAML, …).
    #
    # Lockable / confirmable handling is implicit: Devise's
    # `active_for_authentication?` already gates the Warden user, so a locked
    # or unconfirmed principal yields no signed-in user and {#verify} returns
    # nil — which {Kiosk::Server::Executor} treats as unauthenticated. No
    # extra code needed in the adapter.
    #
    # @example Wiring (Rails initializer)
    #   # config/initializers/kiosk.rb
    #   Kiosk.configure do |c|
    #     c.user_idp = Kiosk::UserIdentityProviders::Devise.new
    #   end
    #
    # @example Per-user role override (in the provider's User model)
    #   class User < ApplicationRecord
    #     devise :database_authenticatable
    #
    #     # Optional. If omitted, the adapter falls back to the first symbol
    #     # in `Kiosk.configuration.roles` (typically `:customer`).
    #     def kiosk_role
    #       support_staff? ? :customer_support : :customer
    #     end
    #   end
    #
    # @note No hard runtime dependency on the `devise` gem. The adapter only
    #   reads the request's Warden user (`request.env["warden"].user`); the
    #   provider's already-installed Devise satisfies the requirement.
    class Devise < Base
      # Raised when {#verify} cannot determine a role to attach to the
      # resolved identity — e.g. the user model defines no `#kiosk_role` and
      # `Kiosk.configuration.roles` is empty.
      class ConfigurationError < StandardError; end

      # Resolve the request into a {Kiosk::Identity}.
      #
      # @param request [#env, #current_user, Hash] the shipped wire passes an
      #   `ActionDispatch::Request` (kiosk-server's
      #   `IdentityResolution.resolve(request)` — the {Base} `#headers, #env`
      #   contract), and the user is read from that request's Warden proxy at
      #   `request.env["warden"].user`. Also accepts a controller-shaped object
      #   exposing `#current_user`, and a raw Rack `env` Hash carrying
      #   `env["warden"]` — for hosts that pass either directly.
      # @return [Kiosk::Identity, nil] identity when a signed-in user is found;
      #   nil when none is (unauthenticated, locked, or unconfirmed — Devise's
      #   `active_for_authentication?` gates the Warden user, so all three
      #   converge on this single signal).
      # @raise [ConfigurationError] when role resolution falls through.
      def verify(request)
        user = current_user_from(request)
        return nil if user.nil?

        Kiosk::Identity.new(
          user_id:  user.public_send(Kiosk.configuration.user_id_column),
          role:     role_for(user),
          actor:    "human",
          agent_id: nil,
          claims:   {},
        )
      end

      private

      # Extract the signed-in user from whatever shape the host passes.
      #
      # Shipped wire (primary): an `ActionDispatch::Request`. It does NOT
      # expose `#current_user` (that is a controller helper, not a request
      # method), so we read the user from the request's Warden proxy —
      # `request.env["warden"].user` — which is how Devise exposes the
      # signed-in principal to Rack-level components once its middleware has
      # run. A not-signed-in request yields a proxy whose `#user` is nil.
      #
      # Also handles a controller-shaped object exposing `#current_user`, and
      # a bare Rack env Hash carrying `env["warden"]`, for hosts that pass
      # either directly.
      def current_user_from(request)
        return request.current_user if request.respond_to?(:current_user)

        env = rack_env_for(request)
        return nil if env.nil?

        warden = env["warden"]
        warden && warden.user
      end

      # The Rack env for a request-shaped object (`#env`) or a bare env Hash;
      # nil for anything else.
      def rack_env_for(request)
        return request.env if request.respond_to?(:env)
        return request     if request.is_a?(Hash)

        nil
      end

      # Each token carries exactly one active role.
      # Resolution order:
      #   1. `user.kiosk_role` (provider opt-in customisation)
      #   2. first symbol in `Kiosk.configuration.roles` (default)
      #   3. raise ConfigurationError (no roles configured)
      #
      # STEP 1 IS VERBATIM, AND THAT INCLUDES `nil` (K-1124). If the model
      # defines the method at all, its answer IS the role — there is no
      # fall-through to step 2 for a nil, and adding one would be a behaviour
      # change in the WRONG direction: `roles.first` is a declaration order,
      # not a privilege order, so an origin declaring `%i[owner customer]`
      # would have nil silently promoted to `owner`.
      #
      # Know what a nil then costs, because it is not local to this method. The
      # role this returns rides `Identity#role` into the account-binding
      # ceremony, and `Kiosk::Server::AccountBinding.rebind`'s no-regression
      # clause (ADR-0011) leaves an agent's `allowed_roles` UNTOUCHED when the
      # ceremony carries no role — so on an origin with more than one declared
      # role, a `#kiosk_role` that can answer nil lets an agent already at the
      # privileged role keep it while being rebound to a human who holds none.
      # No shipped model in this repo does that (`kiosk-test-support`'s
      # `demo_roles_are_total_spec.rb` is the gate on it), and the example below
      # pins the verbatim return so the hazard is measured rather than assumed.
      # A host writing `#kiosk_role` should make it TOTAL: return the
      # least-privileged declared role rather than nil, the way
      # `kiosk-demo-stylish`'s does.
      def role_for(user)
        return user.kiosk_role if user.respond_to?(:kiosk_role)

        roles = Kiosk.configuration.roles
        if roles.nil? || roles.empty?
          raise ConfigurationError, <<~MSG.strip
            Cannot resolve a role for the Devise principal: \
            `Kiosk.configuration.roles` is empty and the user model does not \
            define `#kiosk_role`. Configure at least one role — e.g. \
            `Kiosk.configure { |c| c.roles = %i[customer] }` — or add \
            `def kiosk_role; :customer; end` to your user model.
          MSG
        end

        roles.first
      end
    end
  end
end

require "kiosk/user_identity_providers/devise/version"

# Expose `Kiosk::UserIdentityProviders::Devise::VERSION` so callers don't
# need to know about the build-time-only `DeviseVersion` module.
Kiosk::UserIdentityProviders::Devise::VERSION =
  Kiosk::UserIdentityProviders::DeviseVersion::VERSION
