# frozen_string_literal: true

module Users
  # Sign-up that also takes the name other members of a list will see.
  class RegistrationsController < Devise::RegistrationsController
    before_action :permit_display_name, only: %i[create update]

    private

    DEVISE_ACTION = { "create" => :sign_up, "update" => :account_update }.freeze

    def permit_display_name
      devise_parameter_sanitizer.permit(DEVISE_ACTION.fetch(action_name), keys: [:display_name])
    end
  end
end
