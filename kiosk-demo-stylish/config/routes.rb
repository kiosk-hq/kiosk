# frozen_string_literal: true

Rails.application.routes.draw do
  draw(:kiosk)

  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }

  root "home#index"
end
