# frozen_string_literal: true

Rails.application.routes.draw do
  kiosk do
    queries :my_appointments, :salon_calendar, :salons, :service_menu
    actions :book_appointment
  end

  devise_for :users, controllers: { sessions: 'kiosk/user_identity_providers/devise/sessions' }

  root 'home#index'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'
end
