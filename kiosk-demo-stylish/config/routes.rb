# frozen_string_literal: true

Rails.application.routes.draw do
  kiosk do
    queries :my_appointments, :salon_calendar, :salons, :service_menu
    actions :book_appointment
  end

  devise_for :users

  root 'home#index'

  # What this demo stores and for how long.
  get '/privacy', to: 'privacy#show'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'
end
