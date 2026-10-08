# frozen_string_literal: true

Rails.application.routes.draw do
  draw(:kiosk)

  devise_for :users, controllers: { sessions: "users/sessions" }

  root "home#index"
end
