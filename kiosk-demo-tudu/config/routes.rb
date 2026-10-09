# frozen_string_literal: true

Rails.application.routes.draw do
  draw(:kiosk)

  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions", registrations: "users/registrations" }

  resources :lists, only: %i[index show create] do
    member do
      post "invite"
    end
    resources :todos, only: %i[create] do
      member { post "complete" }
    end
  end

  root to: "lists#index"

  get "/shared", to: "lists#shared"
end
