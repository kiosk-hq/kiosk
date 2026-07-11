# frozen_string_literal: true

require "kiosk"

module Kiosk
  module UserIdentityProviders
    # Devise user-IdP adapter — the bundled-by-default {Kiosk::UserIdentityProviders::Base}
    # implementation for Rails providers that authenticate principals through
    # Devise.
    #
    # The adapter is agnostic about HOW the user logged in: Devise's
    # `database_authenticatable` and `omniauthable` modules both populate
    # `current_user`, so the same one-line read covers password login,
    # passwordless magic-link, and any OmniAuth strategy (Google, GitHub,
    # SAML, …).
    #
    # Lockable / confirmable handling is implicit: Devise's
    # `active_for_authentication?` already gates `current_user`, so a locked
    # or unconfirmed user yields `current_user == nil` and {#verify} returns
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
    #   calls `request.current_user`; the provider's already-installed Devise
    #   satisfies the requirement.
    class Devise < Base
      # Raised when {#verify} cannot determine a role to attach to the
      # resolved identity — e.g. the user model defines no `#kiosk_role` and
      # `Kiosk.configuration.roles` is empty.
      class ConfigurationError < StandardError; end

      # Resolve the request into a {Kiosk::Identity}.
      #
      # @param request [#current_user, Hash] typically the Rails controller
      #   instance (kiosk-server passes `self`); also accepts a Rack `env`
      #   Hash where `env["warden"].user` is the principal (controller
      #   compatibility for hosts that pass raw env).
      # @return [Kiosk::Identity, nil] identity if `current_user` is present;
      #   nil if `current_user` is nil (unauthenticated, locked, or
      #   unconfirmed — all three converge on this single signal).
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

      # Extract `current_user` from either a Rails controller (the common
      # case — kiosk-server passes `self`) or a raw Rack env Hash (the
      # `controller_compat` shim — for hosts that haven't yet been adapted).
      def current_user_from(request)
        return request.current_user if request.respond_to?(:current_user)

        # Rack env shim — Warden stores the authenticated user under
        # `env["warden"].user` after Devise's middleware runs.
        if request.is_a?(Hash) && (warden = request["warden"])
          return warden.user
        end

        nil
      end

      # Each token carries exactly one active role.
      # Resolution order:
      #   1. `user.kiosk_role` (provider opt-in customisation)
      #   2. first symbol in `Kiosk.configuration.roles` (default)
      #   3. raise ConfigurationError (no roles configured)
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
