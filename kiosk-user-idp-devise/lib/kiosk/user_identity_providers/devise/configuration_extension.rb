# frozen_string_literal: true

module Kiosk
  module UserIdentityProviders
    class Devise
      # The Devise adapter's setting, added to {Kiosk::Configuration}.
      module ConfigurationExtension
        # The user model's column that holds the customer's id. Default :id.
        attr_writer :user_id_column

        def user_id_column
          @user_id_column ||= :id
        end
      end
    end
  end
end

Kiosk::Configuration.include(Kiosk::UserIdentityProviders::Devise::ConfigurationExtension)
