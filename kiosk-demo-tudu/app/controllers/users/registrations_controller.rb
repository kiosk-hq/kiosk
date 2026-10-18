# frozen_string_literal: true

module Users
  # Sign-up that also takes the name other members of a list will see.
  class RegistrationsController < Devise::RegistrationsController
    before_action :permit_display_name

    private

    def permit_display_name
      devise_parameter_sanitizer.permit(:sign_up, keys: [:display_name])
      devise_parameter_sanitizer.permit(:account_update, keys: [:display_name])
    end
  end
end
