# frozen_string_literal: true

Rails.application.routes.draw do
  kiosk do
    queries :availability, :my_appointments, :salon_calendar, :salons, :service_menu
    actions :book_appointment
  end

  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }

  root "home#index"
end
