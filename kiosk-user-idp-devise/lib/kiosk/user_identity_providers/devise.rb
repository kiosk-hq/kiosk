# frozen_string_literal: true

require "kiosk"

module Kiosk
  module UserIdentityProviders
    # The user-IdP for a Rails origin whose humans sign in through Devise: it
    # reads the request's Warden user, so password, magic-link and OmniAuth
    # sign-ins all resolve, and a locked or unconfirmed user resolves to nil.
    class Devise < Base
      # Raised when neither the user model nor the configuration names a role.
      class ConfigurationError < StandardError; end

      # @param request [#env, #current_user, Hash] an ActionDispatch::Request,
      #   a controller exposing `#current_user`, or a Rack env Hash
      # @return [Kiosk::Identity, nil] nil when no user is signed in
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

      def current_user_from(request)
        return request.current_user if request.respond_to?(:current_user)

        env = rack_env_for(request)
        return nil if env.nil?

        warden = env["warden"]
        warden && warden.user
      end

      def rack_env_for(request)
        return request.env if request.respond_to?(:env)
        return request     if request.is_a?(Hash)

        nil
      end

      # The model's `#kiosk_role` verbatim, nil included; else the first configured role.
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

Kiosk::UserIdentityProviders::Devise::VERSION =
  Kiosk::UserIdentityProviders::DeviseVersion::VERSION
